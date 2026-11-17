package aauvcore

import (
	"encoding/json"
	"strings"
	"testing"
)

func storeToolLifecycleSearch(t *testing.T, f storeToolFixture) string {
	t.Helper()
	input := f.input(t, "retained-search", "search_chat_history", map[string]any{"query": "synthetic"})
	result, err := f.store.ExecuteConversationTool(input)
	if err != nil || !strings.Contains(result, "current synthetic question") {
		t.Fatalf("synthetic search failed: %v", err)
	}
	storeToolLifecycleRows(t, f.store, 2, true)
	return input
}

func storeToolLifecycleRows(t *testing.T, store *LocalStore, count int, containsSnippet bool) {
	t.Helper()
	rows, err := store.run("SELECT value FROM metadata WHERE key LIKE 'conversation_tool_%'")
	if err != nil || len(rows) != count || strings.Contains(strings.Join(rows, ""), "current synthetic question") != containsSnippet {
		t.Fatalf("unexpected durable tool metadata: rows=%d want=%d snippet=%t want=%t err=%v", len(rows), count,
			strings.Contains(strings.Join(rows, ""), "current synthetic question"), containsSnippet, err)
	}
}

func TestLocalStoreToolLifecycleTerminalUpdate(t *testing.T) {
	for _, phase := range []string{"complete", "failed", "interrupted", "removed", "replaced-question"} {
		t.Run(phase, func(t *testing.T) {
			f := newStoreToolFixture(t, true)
			input := storeToolLifecycleSearch(t, f)
			header := storeToolTestHeader(t, f.store, storeToolTestConversation)
			message := ""
			if phase == "complete" || phase == "removed" {
				delete(header, "replyAttempts")
				if phase == "complete" {
					message = storeToolTestJSON(t, map[string]any{"id": "66666666-6666-4666-8666-000000000001", "role": "assistant", "content": "Synthetic completed answer"})
				}
			} else {
				question, storedPhase := storeToolTestQuestion, phase
				if phase == "replaced-question" {
					question, storedPhase = "11111111-1111-4111-8111-000000000099", "submitted"
				}
				header["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{
					"id": storeToolTestRequest, "userMessageID": question, "phase": storedPhase}}))
			}
			if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), message); err != nil {
				t.Fatal(err)
			}
			storeToolLifecycleRows(t, f.store, 0, false)
			if _, err := f.store.ExecuteConversationTool(input); err == nil {
				t.Fatal("terminated request replay succeeded")
			}
			if phase == "complete" {
				payload, err := f.store.Snapshot()
				if err != nil || !strings.Contains(payload, "Synthetic completed answer") {
					t.Fatal("cleanup lost the completed answer", err)
				}
			}
		})
	}
}

func TestLocalStoreToolLifecycleDelete(t *testing.T) {
	for _, remote := range []bool{false, true} {
		t.Run(map[bool]string{false: "local", true: "remote-tombstone"}[remote], func(t *testing.T) {
			f := newStoreToolFixture(t, true)
			storeToolLifecycleSearch(t, f)
			var err error
			if remote {
				err = f.store.ApplyReplica(storeToolTestJSON(t, replicaRecord{Name: "c-" + storeToolTestConversation,
					Kind: "deleted", Conversation: storeToolTestConversation, Revision: "8000000000000000000"}))
			} else {
				err = f.store.Delete(storeToolTestConversation)
			}
			if err != nil {
				t.Fatal(err)
			}
			storeToolLifecycleRows(t, f.store, 0, false)
			rows, err := f.store.run("SELECT id FROM conversation WHERE id=?", storeToolTestConversation)
			if err != nil || len(rows) != 0 {
				t.Fatal("conversation was not deleted", err)
			}
		})
	}
}

func TestLocalStoreToolLifecycleReplicaHeaderAndQuestion(t *testing.T) {
	f := newStoreToolFixture(t, true)
	input := storeToolLifecycleSearch(t, f)
	prior, err := f.store.ExecuteConversationTool(input)
	if err != nil {
		t.Fatal(err)
	}
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	delete(header, "replyAttempts") // Replica headers never include local attempts.
	header["title"] = json.RawMessage(`"Synthetic remote title"`)
	if err := f.store.ApplyReplica(storeToolTestJSON(t, replicaRecord{Name: "c-" + storeToolTestConversation,
		Kind: "conversation", Conversation: storeToolTestConversation, Revision: "8000000000000000000",
		Payload: storeToolTestJSON(t, header)})); err != nil {
		t.Fatal(err)
	}
	storeToolLifecycleRows(t, f.store, 2, true)
	if replay, err := f.store.ExecuteConversationTool(input); err != nil || replay != prior {
		t.Fatal("remote header update invalidated a local active attempt", err)
	}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, replicaRecord{Name: "m-" + storeToolTestQuestion,
		Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000000",
		Payload: storeToolTestJSON(t, map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "recalled", "status": "deleted"})})); err != nil {
		t.Fatal(err)
	}
	storeToolLifecycleRows(t, f.store, 0, false)
	if _, err := f.store.ExecuteConversationTool(input); err == nil {
		t.Fatal("recalled question replay succeeded")
	}
}

func TestLocalStoreToolLifecycleReopenCleansLegacyOrphans(t *testing.T) {
	for _, orphan := range []string{"completed", "deleted-conversation", "missing-question", "missing-request", "malformed-request"} {
		t.Run(orphan, func(t *testing.T) {
			f := newStoreToolFixture(t, true)
			storeToolLifecycleSearch(t, f)
			// Simulate an older build/crash by changing durable records directly;
			// the public OpenLocalStore must reclaim already existing orphan rows.
			var err error
			switch orphan {
			case "completed":
				header := storeToolTestHeader(t, f.store, storeToolTestConversation)
				delete(header, "replyAttempts")
				_, err = f.store.run("UPDATE conversation SET header=? WHERE id=?", storeToolTestJSON(t, header), storeToolTestConversation)
			case "deleted-conversation":
				_, err = f.store.run("DELETE FROM conversation WHERE id=?", storeToolTestConversation)
			case "missing-question":
				_, err = f.store.run("DELETE FROM message WHERE id=?", storeToolTestQuestion)
			case "missing-request":
				_, err = f.store.run("DELETE FROM metadata WHERE key=?", storeToolRequestPrefix+storeToolTestRequest)
			case "malformed-request":
				_, err = f.store.run("UPDATE metadata SET value=? WHERE key=?", "{", storeToolRequestPrefix+storeToolTestRequest)
			}
			if err != nil {
				t.Fatal(err)
			}
			f.store.Close()
			reopened, err := OpenLocalStore(f.path)
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			storeToolLifecycleRows(t, reopened, 0, false)
		})
	}
}

func TestLocalStoreToolLifecycleMultipleDurableActiveRequests(t *testing.T) {
	f := newStoreToolFixture(t, true)
	input := storeToolLifecycleSearch(t, f)
	first, err := f.store.ExecuteConversationTool(input)
	if err != nil {
		t.Fatal(err)
	}
	otherRequest := "77777777-7777-4777-8777-000000000001"
	otherQuestion := "11111111-1111-4111-8111-000000000005"
	header := storeToolTestHeader(t, f.store, storeToolTestOtherConversation)
	header["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{
		"id": otherRequest, "userMessageID": otherQuestion, "phase": "preparing"}}))
	if err = f.store.Update(storeToolTestOtherConversation, storeToolTestJSON(t, header), ""); err != nil {
		t.Fatal(err)
	}
	otherInput := storeToolTestJSON(t, storeToolInput{ConversationID: storeToolTestOtherConversation, UserMessageID: otherQuestion,
		RequestID: otherRequest, CallID: "second-window", Name: "search_chat_history", Arguments: json.RawMessage(`{"query":"synthetic"}`), ExpectedBot: f.bot})
	secondWindow, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer secondWindow.Close()
	second, err := secondWindow.ExecuteConversationTool(otherInput)
	if err != nil {
		t.Fatal(err)
	}
	storeToolLifecycleRows(t, f.store, 4, true)
	f.store.Close()
	reopened, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	storeToolLifecycleRows(t, reopened, 4, true)
	if replay, err := reopened.ExecuteConversationTool(input); err != nil || replay != first {
		t.Fatal("reopen lost first active request replay", err)
	}
	if replay, err := secondWindow.ExecuteConversationTool(otherInput); err != nil || replay != second {
		t.Fatal("another durable active request was removed", err)
	}
	if err := reopened.Delete(storeToolTestConversation); err != nil {
		t.Fatal(err)
	}
	storeToolLifecycleRows(t, reopened, 2, false)
	if replay, err := secondWindow.ExecuteConversationTool(otherInput); err != nil || replay != second {
		t.Fatal("deleting one conversation invalidated another window", err)
	}
}

func TestLocalStoreToolLifecycleCleanupRollsBackWithUpdate(t *testing.T) {
	f := newStoreToolFixture(t, true)
	input := storeToolLifecycleSearch(t, f)
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	delete(header, "replyAttempts")
	// A cleanup failure must roll back the answer/header mutation as well.
	if err := f.store.exec(`CREATE TEMP TRIGGER reject_receipt_cleanup BEFORE DELETE ON metadata
WHEN OLD.key LIKE 'conversation_tool_receipt:%' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;`); err != nil {
		t.Fatal(err)
	}
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err == nil {
		t.Fatal("header committed despite receipt cleanup failure")
	}
	storeToolLifecycleRows(t, f.store, 2, true)
	if _, err := f.store.ExecuteConversationTool(input); err != nil {
		t.Fatal("failed transaction removed the active attempt", err)
	}
}
