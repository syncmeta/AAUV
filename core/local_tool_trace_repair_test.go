package aauvcore

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalToolTraceOlderRevisionNeverAuthorizesAttachmentBytes(t *testing.T) {
	for _, metadata := range []string{"none", "terminal-current", "terminal-incoming"} {
		for _, missing := range []bool{false, true} {
			t.Run(metadata+map[bool]string{false: "-existing", true: "-missing"}[missing], func(t *testing.T) {
				store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
				if err != nil {
					t.Fatal(err)
				}
				defer store.Close()
				if err = store.Insert(`[{"id":"`+storeToolTestConversation+`","title":"synthetic","messages":[]}]`, false); err != nil {
					t.Fatal(err)
				}
				const file = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
				currentPayload := map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "same body", "attachments": []any{map[string]any{"fileName": file, "size": 3, "name": "fixture.bin"}}}
				stalePayload := map[string]any{}
				for k, v := range currentPayload {
					stalePayload[k] = v
				}
				if metadata != "none" {
					a, b := "succeeded", "running"
					if metadata == "terminal-incoming" {
						a, b = b, a
					}
					trace := func(state string) map[string]any {
						return map[string]any{"version": 1, "requestID": storeToolTestRequest, "runRevision": "0000000000000000001", "entries": []any{map[string]any{"id": traceCallOne, "sequence": 0, "function": "search_chat_history", "state": state}}}
					}
					currentPayload["localToolTrace"] = trace(a)
					stalePayload["localToolTrace"] = trace(b)
				}
				current := replicaRecord{Name: "m-" + storeToolTestQuestion, Kind: "message", Conversation: storeToolTestConversation, Revision: "0000000000000000002", Payload: storeToolTestJSON(t, currentPayload)}
				stale := current
				stale.Revision = "0000000000000000001"
				stale.Payload = storeToolTestJSON(t, stalePayload)
				if err = store.ApplyReplica(storeToolTestJSON(t, current)); err != nil {
					t.Fatal(err)
				}
				asset := filepath.Join(t.TempDir(), file)
				if !missing {
					if err = os.WriteFile(asset, []byte{42, 21, 0}, 0600); err != nil {
						t.Fatal(err)
					}
				}
				needed, err := store.NeedsReplicaPayload(storeToolTestJSON(t, stale))
				if err != nil {
					t.Fatal(err)
				}
				// Mirror the actual Swift boundary: existing bytes conflict; missing bytes
				// would be created if the old packet were incorrectly declared eligible.
				conflict, wroteStale := false, false
				if needed {
					if _, err = os.Stat(asset); err == nil {
						conflict = true
					} else {
						if err = os.WriteFile(asset, []byte{0, 0, 0}, 0600); err != nil {
							t.Fatal(err)
						}
						wroteStale = true
					}
				}
				if needed || conflict || wroteStale {
					t.Fatalf("lower-revision packet got file authority: needed=%t existingConflict=%t staleWrite=%t", needed, conflict, wroteStale)
				}
				accepted, err := store.ApplyReplicaChecked(storeToolTestJSON(t, stale))
				if err != nil {
					t.Fatal(err)
				}
				if metadata == "terminal-incoming" {
					if !accepted || traceStored(t, store, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "succeeded" {
						t.Fatal("metadata-only improvement was blocked")
					}
				} else if accepted {
					t.Fatal("unchanged stale body falsely ACKed")
				}
				if missing {
					if _, err = os.Stat(asset); !os.IsNotExist(err) {
						t.Fatal("old missing asset was backfilled")
					}
				} else {
					bytes, _ := os.ReadFile(asset)
					if string(bytes) != string([]byte{42, 21, 0}) {
						t.Fatal("current asset changed")
					}
				}
				// A genuine exact CURRENT record is still permitted to repair its files.
				latest := traceSyncRecord(t, store, current.Name)
				if needed, err = store.NeedsReplicaPayload(storeToolTestJSON(t, latest)); err != nil || !needed {
					t.Fatal("exact current replay lost repair permission", err)
				}
			})
		}
	}
}
