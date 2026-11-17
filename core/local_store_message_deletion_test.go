package aauvcore

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

type messageDeleter interface{ DeleteMessage(string, string) error }

func deleteSingleMessage(t *testing.T, s *LocalStore, c, m string) error {
	t.Helper()
	api, ok := any(s).(messageDeleter)
	if !ok {
		t.Fatal("missing LocalStore.DeleteMessage: current API cannot remove a single local bot-chat message")
	}
	return api.DeleteMessage(c, m)
}

func TestDeleteMessageKeepsOtherRepliesAndCleansAttempt(t *testing.T) {
	f := newStoreToolFixture(t, true)
	input := storeToolLifecycleSearch(t, f)
	const answer = "55555555-5555-4555-8555-000000000001"
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	msg := storeToolTestJSON(t, map[string]any{"id": answer, "role": "assistant", "content": "retained synthetic answer", "replyTo": storeToolTestQuestion})
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), msg); err != nil {
		t.Fatal(err)
	}
	if err := deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	snapshot, err := f.store.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(snapshot, "current synthetic question") || !strings.Contains(snapshot, "retained synthetic answer") || !strings.Contains(snapshot, `"replyTo":"`+storeToolTestQuestion+`"`) {
		t.Fatal("delete must remove exactly the target and preserve child association")
	}
	header = storeToolTestHeader(t, f.store, storeToolTestConversation)
	if header["compression"] != nil || header["replyAttempts"] != nil {
		t.Fatal("request/cache still live")
	}
	storeToolLifecycleRows(t, f.store, 0, false)
	if _, err = f.store.ExecuteConversationTool(input); err == nil {
		t.Fatal("terminated tool replay succeeded")
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal("repeat deletion not idempotent", err)
	}
	pending, err := f.store.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(pending, `"kind":"message_deleted"`) || strings.Contains(pending, "current synthetic question") {
		t.Fatal("target body retained in replica")
	}
}

func TestDeleteMessageTwoConnectionsAndReplay(t *testing.T) {
	f := newStoreToolFixture(t, false)
	second, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	rows, err := f.store.run("SELECT "+replicaJSON+" FROM replica WHERE name=?", "m-"+storeToolTestQuestion)
	if err != nil {
		t.Fatal(err)
	}
	var prior replicaRecord
	if json.Unmarshal([]byte(rows[0]), &prior) != nil {
		t.Fatal("bad fixture")
	}
	if err = deleteSingleMessage(t, second, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	prior.Revision = "8000000000000000000"
	accepted, err := f.store.ApplyReplicaChecked(storeToolTestJSON(t, prior))
	if err != nil || accepted {
		t.Fatal("newer old-message replay revived deleted identity", err)
	}
	if err = f.store.Update(storeToolTestConversation, `{"id":"`+storeToolTestConversation+`","title":"stale"}`, prior.Payload); err == nil {
		t.Fatal("append reused deleted identity")
	}
	if err = f.store.PrepareReplica(); err != nil {
		t.Fatal(err)
	}
	snapshot, err := f.store.Snapshot()
	if err != nil || strings.Contains(snapshot, "current synthetic question") {
		t.Fatal("second connection/reseed revived message", err)
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestOtherConversation, storeToolTestQuestion); err == nil {
		t.Fatal("cross-chat tombstone reused")
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestConversation, "55555555-5555-4555-8555-000000009999"); err == nil {
		t.Fatal("missing local message forged tombstone")
	}
}

func TestDeleteMessageRemoteBeforeParentAndReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "synthetic.sqlite")
	store, err := OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	tombstone := replicaRecord{Name: "m-" + storeToolTestQuestion, Kind: "message_deleted", Conversation: storeToolTestConversation, Revision: "1000000000000000000"}
	if err = store.ApplyReplica(storeToolTestJSON(t, tombstone)); err != nil {
		t.Fatal(err)
	}
	header := replicaRecord{Name: "c-" + storeToolTestConversation, Kind: "conversation", Conversation: storeToolTestConversation, Revision: "2000000000000000000", Payload: `{"id":"` + storeToolTestConversation + `","title":"remote"}`}
	if err = store.ApplyReplica(storeToolTestJSON(t, header)); err != nil {
		t.Fatal(err)
	}
	old := replicaRecord{Name: tombstone.Name, Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: `{"id":"` + storeToolTestQuestion + `","role":"user","content":"synthetic old body"}`}
	if err = store.ApplyReplica(storeToolTestJSON(t, old)); err != nil {
		t.Fatal(err)
	}
	store.Close()
	store, err = OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	snapshot, err := store.Snapshot()
	if err != nil || strings.Contains(snapshot, "synthetic old body") {
		t.Fatal("old record revived after reopen", err)
	}
	tombstone.Conversation = storeToolTestOtherConversation
	tombstone.Revision = "8000000000000000001"
	if err = store.ApplyReplica(storeToolTestJSON(t, tombstone)); err == nil {
		t.Fatal("cross-chat remote tombstone accepted")
	}
}

func deletionSnapshotHeader(t *testing.T, s *LocalStore, c string) map[string]json.RawMessage {
	t.Helper()
	raw, err := s.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	var chats []map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &chats) != nil {
		t.Fatal("invalid snapshot")
	}
	for _, h := range chats {
		var id string
		_ = json.Unmarshal(h["id"], &id)
		if id == c {
			delete(h, "messages")
			return h
		}
	}
	t.Fatal("chat missing")
	return nil
}

func TestDeleteMessageHistoryRevisionRejectsStaleCacheAndAllowsFreshCache(t *testing.T) {
	f := newStoreToolFixture(t, false)
	second, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	old := deletionSnapshotHeader(t, second, storeToolTestConversation)
	// The summary contains text from the target, but its random samples do not.
	old["compression"] = json.RawMessage(`{"fingerprint":"old-plan","summary":"synthetic deleted private summary","compressedSamples":[],"historicalSamples":[],"checkpoint":{"scope":"old","summary":"synthetic checkpoint"}}`)
	if err = second.Update(storeToolTestConversation, storeToolTestJSON(t, old), ""); err != nil {
		t.Fatal(err)
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	const late = "55555555-5555-4555-8555-000000000044"
	appended := storeToolTestJSON(t, map[string]any{"id": late, "role": "user", "content": "synthetic stale appended message"})
	if err = second.Update(storeToolTestConversation, storeToolTestJSON(t, old), appended); err == nil || err.Error() != "stale_conversation_history" {
		t.Fatal("old unsampled summary/header accepted", err)
	}
	raw, _ := f.store.Snapshot()
	if strings.Contains(raw, "deleted private summary") || strings.Contains(raw, late) || strings.Contains(raw, "synthetic checkpoint") {
		t.Fatal("stale transaction had effects")
	}
	fresh := deletionSnapshotHeader(t, second, storeToolTestConversation)
	var revision string
	if json.Unmarshal(fresh["historyRevision"], &revision) != nil || len(revision) != 64 {
		t.Fatal("missing derived revision")
	}
	fresh["compression"] = json.RawMessage(`{"fingerprint":"new-plan","summary":"synthetic clean rebuilt summary"}`)
	if err = second.Update(storeToolTestConversation, storeToolTestJSON(t, fresh), appended); err != nil {
		t.Fatal("fresh summary rejected", err)
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	after := deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	if string(after["historyRevision"]) != string(fresh["historyRevision"]) || !strings.Contains(string(after["compression"]), "clean rebuilt") {
		t.Fatal("idempotent delete invalidated later clean state")
	}
	persisted := storeToolTestHeader(t, f.store, storeToolTestConversation)
	if persisted["historyRevision"] != nil {
		t.Fatal("derived revision persisted as authority")
	}
	records, _ := f.store.run("SELECT payload FROM replica WHERE kind='conversation'")
	if strings.Contains(strings.Join(records, ""), "historyRevision") {
		t.Fatal("local revision leaked to sync header")
	}
	tombstone := replicaRecord{Name: "m-" + storeToolTestQuestion, Kind: messageDeletedKind, Conversation: storeToolTestConversation, Revision: "8000000000000000000"}
	if err = f.store.ApplyReplica(storeToolTestJSON(t, tombstone)); err != nil {
		t.Fatal(err)
	}
	after = deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	if !strings.Contains(string(after["compression"]), "clean rebuilt") {
		t.Fatal("replayed tombstone cleared clean state")
	}
}

func TestDeleteMessageLateChoicesAndChildHistory(t *testing.T) {
	f := newStoreToolFixture(t, false)
	const answer = "55555555-5555-4555-8555-000000000002"
	const unknown = "55555555-5555-4555-8555-000000000003"
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	reply := storeToolTestJSON(t, map[string]any{"id": answer, "role": "assistant", "content": "synthetic only delete reply", "replyTo": storeToolTestQuestion})
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), reply); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.SetReplyChoice(storeToolTestConversation, storeToolTestQuestion, answer); err != nil {
		t.Fatal(err)
	}
	if err := deleteSingleMessage(t, f.store, storeToolTestConversation, answer); err != nil {
		t.Fatal(err)
	}
	// This tests a normalized CURRENT replay, not repair from an older
	// trace-derived body. Preserve this peer's actual run envelope: omitting it
	// would force a new derived revision while retaining local trace, making
	// the next packet stale and therefore ineligible to supply file bytes.
	parentRows, err := f.store.run("SELECT payload FROM message WHERE id=?", storeToolTestQuestion)
	if err != nil || len(parentRows) != 1 {
		t.Fatal("missing parent", err)
	}
	var parentFields map[string]json.RawMessage
	if json.Unmarshal([]byte(parentRows[0]), &parentFields) != nil {
		t.Fatal("invalid parent")
	}
	promptFields := map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "retained prompt", "selectedReplyID": answer}
	if raw := parentFields["localToolTrace"]; len(raw) > 0 {
		promptFields["localToolTrace"] = raw
	}
	oldPrompt := replicaRecord{Name: "m-" + storeToolTestQuestion, Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: storeToolTestJSON(t, promptFields)}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, oldPrompt)); err != nil {
		t.Fatal(err)
	}
	if needed, err := f.store.NeedsReplicaPayload(storeToolTestJSON(t, oldPrompt)); err != nil || !needed {
		t.Fatal("normalized exact replay cannot repair attachment payload", err)
	}
	raw, _ := f.store.Snapshot()
	if strings.Contains(raw, "selectedReplyID") {
		t.Fatal("late prompt restored deleted reply choice")
	}
	header := replicaRecord{Name: "c-" + storeToolTestConversation, Kind: "conversation", Conversation: storeToolTestConversation, Revision: "8000000000000000001", Payload: storeToolTestJSON(t, map[string]any{"id": storeToolTestConversation, "title": "late header", "historyRevision": "untrusted", "selectedReplies": map[string]string{storeToolTestQuestion: answer, "unknown-parent": unknown}})}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, header)); err != nil {
		t.Fatal(err)
	}
	h = deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	if strings.Contains(string(h["selectedReplies"]), answer) || !strings.Contains(string(h["selectedReplies"]), unknown) {
		t.Fatal("known deletion not filtered or unknown selection lost")
	}
	stored, _ := f.store.run("SELECT payload FROM replica WHERE name=?", "c-"+storeToolTestConversation)
	if strings.Contains(stored[0], "historyRevision") || strings.Contains(stored[0], answer) {
		t.Fatal("untrusted header fields retained in sync payload")
	}
	oldPrompt.Revision = "8000000000000000002"
	oldPrompt.Payload = storeToolTestJSON(t, map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "retained prompt", "selectedReplyID": unknown})
	if err := f.store.ApplyReplica(storeToolTestJSON(t, oldPrompt)); err != nil {
		t.Fatal(err)
	}
	raw, _ = f.store.Snapshot()
	if !strings.Contains(raw, unknown) {
		t.Fatal("not-yet-arrived normal choice dropped")
	}
	if err := deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	child := replicaRecord{Name: "m-" + unknown, Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000003", Payload: storeToolTestJSON(t, map[string]any{"id": unknown, "role": "assistant", "content": "synthetic late retained child", "replyTo": storeToolTestQuestion})}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, child)); err != nil {
		t.Fatal("legitimate historical child rejected", err)
	}
	raw, _ = f.store.Snapshot()
	if !strings.Contains(raw, "late retained child") || !strings.Contains(raw, `"replyTo":"`+storeToolTestQuestion+`"`) {
		t.Fatal("child deleted or reparented")
	}
	fresh := deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, fresh), storeToolTestJSON(t, map[string]any{"id": "55555555-5555-4555-8555-000000000099", "role": "assistant", "content": "forbidden new child", "replyTo": storeToolTestQuestion})); err == nil || err.Error() != "message_parent_was_deleted" {
		t.Fatal("new local answer to deleted prompt accepted", err)
	}
}

func TestDeleteMessageAttachmentReferencesRetainSharedAndParentlessFiles(t *testing.T) {
	f := newStoreToolFixture(t, false)
	api, ok := any(f.store).(interface{ AttachmentReferences() (string, error) })
	if !ok {
		t.Fatal("missing attachment snapshot API")
	}
	const file = "66666666-6666-4666-8666-000000000001"
	const shared = "66666666-6666-4666-8666-000000000002"
	const orphan = "66666666-6666-4666-8666-000000000003"
	const answer = "55555555-5555-4555-8555-000000000005"
	attachment := map[string]any{"id": "77777777-7777-4777-8777-000000000001", "fileName": file, "name": "synthetic.txt", "size": 4}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	h["attachments"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"fileName": shared, "size": 3}}))
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), storeToolTestJSON(t, map[string]any{"id": answer, "role": "assistant", "content": "synthetic file owner", "attachments": []any{attachment}})); err != nil {
		t.Fatal(err)
	}
	parentless := replicaRecord{Name: "m-55555555-5555-4555-8555-000000000006", Kind: "message", Conversation: "11111111-1111-4111-8111-000000000099", Revision: "1000000000000000000", Payload: storeToolTestJSON(t, map[string]any{"id": "55555555-5555-4555-8555-000000000006", "role": "user", "content": "parentless file", "attachments": []any{map[string]any{"fileName": orphan, "size": 5}, attachment}})}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, parentless)); err != nil {
		t.Fatal(err)
	}
	if err := deleteSingleMessage(t, f.store, storeToolTestConversation, answer); err != nil {
		t.Fatal(err)
	}
	refs, err := api.AttachmentReferences()
	if err != nil || !strings.Contains(refs, file) || !strings.Contains(refs, shared) || !strings.Contains(refs, orphan) {
		t.Fatal("shared or parentless file lost", err)
	}
	parentless.Kind = messageDeletedKind
	parentless.Payload = ""
	parentless.Revision = "2000000000000000000"
	if err = f.store.ApplyReplica(storeToolTestJSON(t, parentless)); err != nil {
		t.Fatal(err)
	}
	refs, err = api.AttachmentReferences()
	if err != nil || strings.Contains(refs, file) || strings.Contains(refs, orphan) || !strings.Contains(refs, shared) {
		t.Fatal("deleted-only refs still retained or chat file lost", err)
	}
	if _, err = f.store.run("UPDATE conversation SET header=json_set(header,'$.attachments',json('[{\"fileName\":\"../forbidden\",\"size\":1}]')) WHERE id=?", storeToolTestConversation); err != nil {
		t.Fatal(err)
	}
	if _, err = api.AttachmentReferences(); err == nil {
		t.Fatal("malformed refs produced permissive cleanup snapshot")
	}
}

func TestDeleteMessageBackupRestoreCannotReuseDeletedIdentity(t *testing.T) {
	f := newStoreToolFixture(t, false)
	original, err := f.store.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	manifest := `{"version":2,"conversations":` + original + `}`
	path := filepath.Join(t.TempDir(), "synthetic.aauvbackup")
	if err = WriteBackupZIP(path, t.TempDir(), manifest); err != nil {
		t.Fatal(err)
	}
	restored, err := ReadBackupZIP(path, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Conversations json.RawMessage `json:"conversations"`
	}
	if json.Unmarshal([]byte(restored), &envelope) != nil {
		t.Fatal("invalid restored manifest")
	}
	if err = deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	if err = f.store.Delete(storeToolTestConversation); err != nil {
		t.Fatal(err)
	}
	if err = f.store.Delete(storeToolTestOtherConversation); err != nil {
		t.Fatal(err)
	}
	if err = f.store.RestoreCopies(string(envelope.Conversations), "[]"); err == nil {
		t.Fatal("stale backup reused removed identity")
	}
	raw, _ := f.store.Snapshot()
	if raw != "[]" {
		t.Fatal("failed restore was not atomic")
	}
	// The app restores intentional copies with new UUIDs, not the removed IDs.
	copies := strings.ReplaceAll(string(envelope.Conversations), storeToolTestConversation, "11111111-1111-4111-8111-000000000088")
	copies = strings.ReplaceAll(copies, storeToolTestQuestion, "11111111-1111-4111-8111-000000000089")
	copies = strings.ReplaceAll(copies, storeToolTestOtherConversation, "11111111-1111-4111-8111-000000000087")
	copies = strings.ReplaceAll(copies, "11111111-1111-4111-8111-000000000005", "11111111-1111-4111-8111-000000000086")
	var docs []map[string]json.RawMessage
	if json.Unmarshal([]byte(copies), &docs) != nil {
		t.Fatal("bad fixture")
	}
	for _, doc := range docs {
		doc["historyRevision"] = json.RawMessage(`"untrusted imported epoch"`)
	}
	if err = f.store.RestoreCopies(storeToolTestJSON(t, docs), "[]"); err != nil {
		t.Fatal("new-identity copy restore rejected", err)
	}
	raw, _ = f.store.Snapshot()
	if !strings.Contains(raw, "current synthetic question") || strings.Contains(raw, "historyRevision") {
		t.Fatal("new copies retained untrusted deletion authority")
	}
}

func TestDeleteMessageStartupAndPrepareRepairCannotRestageBody(t *testing.T) {
	for _, mode := range []string{"startup", "prepare"} {
		t.Run(mode, func(t *testing.T) {
			f := newStoreToolFixture(t, false)
			if err := deleteSingleMessage(t, f.store, storeToolTestConversation, storeToolTestQuestion); err != nil {
				t.Fatal(err)
			}
			// A pre-feature writer or interrupted legacy migration left a row next
			// to the durable tombstone. Public current append rejects this shape.
			bad := storeToolTestJSON(t, map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "synthetic forbidden legacy restored body"})
			if _, err := f.store.run("INSERT INTO message(id,conversation_id,payload) VALUES(?,?,?)", storeToolTestQuestion, storeToolTestConversation, bad); err != nil {
				t.Fatal(err)
			}
			if mode == "startup" {
				f.store.Close()
				reopened, err := OpenLocalStore(f.path)
				if err != nil {
					t.Fatal(err)
				}
				defer reopened.Close()
				f.store = reopened
			} else {
				if err := f.store.PrepareReplica(); err != nil {
					t.Fatal(err)
				}
			}
			raw, err := f.store.Snapshot()
			if err != nil || strings.Contains(raw, "forbidden legacy") {
				t.Fatal("legacy row resurrected", err)
			}
			rows, err := f.store.run("SELECT kind||':'||payload FROM replica WHERE name=?", "m-"+storeToolTestQuestion)
			if err != nil || len(rows) != 1 || rows[0] != messageDeletedKind+":" {
				t.Fatal("tombstone overwritten", err)
			}
		})
	}
}

func TestDeleteMessageMalformedRemoteRejectedAtomically(t *testing.T) {
	f := newStoreToolFixture(t, false)
	cases := []replicaRecord{
		{Name: "m-" + storeToolTestQuestion, Kind: messageDeletedKind, Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: "{}"},
		{Name: "not-a-message", Kind: messageDeletedKind, Conversation: storeToolTestConversation, Revision: "8000000000000000000"},
		{Name: "m-" + storeToolTestQuestion, Kind: messageDeletedKind, Conversation: "", Revision: "8000000000000000000"},
		{Name: "m-" + storeToolTestQuestion, Kind: messageDeletedKind, Conversation: storeToolTestOtherConversation, Revision: "8000000000000000000"},
	}
	before, _ := f.store.Snapshot()
	for _, record := range cases {
		if err := f.store.ApplyReplica(storeToolTestJSON(t, record)); err == nil {
			t.Fatal("invalid remote tombstone accepted")
		}
		after, _ := f.store.Snapshot()
		if after != before {
			t.Fatal("invalid delete changed database")
		}
	}
	for _, ids := range [][2]string{{"not-uuid", storeToolTestQuestion}, {storeToolTestConversation, "bad"}, {storeToolTestOtherConversation, storeToolTestQuestion}} {
		if err := deleteSingleMessage(t, f.store, ids[0], ids[1]); err == nil {
			t.Fatal("invalid local delete accepted")
		}
	}
}

func TestDeleteMessageAssistantAlsoStopsCurrentToolRequest(t *testing.T) {
	f := newStoreToolFixture(t, true)
	input := storeToolLifecycleSearch(t, f)
	const answer = "55555555-5555-4555-8555-000000000055"
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), storeToolTestJSON(t, map[string]any{"id": answer, "role": "assistant", "content": "synthetic earlier answer"})); err != nil {
		t.Fatal(err)
	}
	if err := deleteSingleMessage(t, f.store, storeToolTestConversation, answer); err != nil {
		t.Fatal(err)
	}
	storeToolLifecycleRows(t, f.store, 0, false)
	if _, err := f.store.ExecuteConversationTool(input); err == nil {
		t.Fatal("old request survived changed history")
	}
	raw, _ := f.store.Snapshot()
	if !strings.Contains(raw, "current synthetic question") {
		t.Fatal("deletion removed other prompt")
	}
}

func TestDeleteMessageParentlessReplicaChoicesAreAlsoSanitized(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const target = "55555555-5555-4555-8555-000000000066"
	prompt := replicaRecord{Name: "m-" + storeToolTestQuestion, Kind: "message", Conversation: storeToolTestConversation, Revision: "1000000000000000000", Payload: storeToolTestJSON(t, map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "synthetic parentless prompt", "selectedReplyID": target})}
	if err = store.ApplyReplica(storeToolTestJSON(t, prompt)); err != nil {
		t.Fatal(err)
	}
	tombstone := replicaRecord{Name: "m-" + target, Kind: messageDeletedKind, Conversation: storeToolTestConversation, Revision: "2000000000000000000"}
	if err = store.ApplyReplica(storeToolTestJSON(t, tombstone)); err != nil {
		t.Fatal(err)
	}
	rows, _ := store.run("SELECT payload FROM replica WHERE name=?", prompt.Name)
	if len(rows) != 1 || strings.Contains(rows[0], "selectedReplyID") {
		t.Fatal("parentless replica retained deleted choice")
	}
	header := replicaRecord{Name: "c-" + storeToolTestConversation, Kind: "conversation", Conversation: storeToolTestConversation, Revision: "3000000000000000000", Payload: storeToolTestJSON(t, map[string]any{"id": storeToolTestConversation, "title": "synthetic parent later"})}
	if err = store.ApplyReplica(storeToolTestJSON(t, header)); err != nil {
		t.Fatal(err)
	}
	raw, _ := store.Snapshot()
	if !strings.Contains(raw, "parentless prompt") || strings.Contains(raw, "selectedReplyID") {
		t.Fatal("late parent rematerialized deleted choice")
	}
}

func TestDeleteMessageAcceptsSwiftUppercaseForStoredLowercaseUUIDs(t *testing.T) {
	const chat = "abcdef12-abcd-4abc-8abc-abcdef123456"
	const message = "bcdef123-bcde-4bcd-8bcd-bcdef1234567"
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	data := storeToolTestJSON(t, []any{map[string]any{"id": chat, "title": "synthetic lowercase", "messages": []any{map[string]any{"id": message, "role": "user", "content": "synthetic lowercase target"}}}})
	if err = store.Insert(data, false); err != nil {
		t.Fatal(err)
	}
	if err = deleteSingleMessage(t, store, strings.ToUpper(chat), strings.ToUpper(message)); err != nil {
		t.Fatal("Swift canonical uppercase UUID failed against lowercase stored identity", err)
	}
	if err = deleteSingleMessage(t, store, strings.ToUpper(chat), strings.ToUpper(message)); err != nil {
		t.Fatal("uppercase repeated deletion failed", err)
	}
	rows, err := store.run("SELECT name||':'||conversation||':'||kind FROM replica WHERE kind=?", messageDeletedKind)
	if err != nil || len(rows) != 1 || rows[0] != "m-"+message+":"+chat+":"+messageDeletedKind {
		t.Fatal("deletion rewrote the stored UUID spelling or minted a second identity", err)
	}
	snapshot, _ := store.Snapshot()
	if strings.Contains(snapshot, "lowercase target") {
		t.Fatal("lowercase target survived")
	}
}

func TestDeleteMessageAmbiguousUUIDCaseVariantsAreRejected(t *testing.T) {
	const chat = "abcdef12-abcd-4abc-8abc-abcdef123456"
	const message = "bcdef123-bcde-4bcd-8bcd-bcdef1234567"
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	docs := []any{}
	for _, ids := range [][2]string{{chat, message}, {strings.ToUpper(chat), strings.ToUpper(message)}} {
		docs = append(docs, map[string]any{"id": ids[0], "title": "synthetic collision", "messages": []any{map[string]any{"id": ids[1], "role": "user", "content": "synthetic retain both"}}})
	}
	if err = store.Insert(storeToolTestJSON(t, docs), false); err != nil {
		t.Fatal(err)
	}
	before, _ := store.Snapshot()
	if err = deleteSingleMessage(t, store, strings.ToUpper(chat), strings.ToUpper(message)); err == nil || err.Error() != "message_identity_ambiguous" {
		t.Fatal("ambiguous spelling chose a message", err)
	}
	after, _ := store.Snapshot()
	if after != before {
		t.Fatal("ambiguous failure changed database")
	}
}
