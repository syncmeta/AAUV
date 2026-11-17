package aauvcore

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type breadcrumbRecorder interface{ RecordConversationToolBreadcrumb(string) (string, error) }

func traceRecord(t *testing.T, f storeToolFixture, event map[string]any) (string, error) {
	t.Helper()
	api, ok := any(f.store).(breadcrumbRecorder)
	if !ok {
		t.Fatal("missing RecordConversationToolBreadcrumb")
	}
	h := deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	var revision string
	_ = json.Unmarshal(h["historyRevision"], &revision)
	return api.RecordConversationToolBreadcrumb(storeToolTestJSON(t, map[string]any{"conversation_id": storeToolTestConversation, "user_message_id": storeToolTestQuestion, "request_id": storeToolTestRequest, "history_revision": revision, "expected_bot": f.bot, "event": event}))
}
func traceEvent(id, state string) map[string]any {
	return map[string]any{"id": id, "function": "search_chat_history", "state": state}
}

const traceCallOne = "abcdef12-abcd-4abc-8abc-abcdef123456"
const traceCallTwo = "bcdef123-bcde-4bcd-8bcd-bcdef1234567"

func TestLocalToolTraceAtomicRecordAndTerminalState(t *testing.T) {
	f := newStoreToolFixture(t, true)
	start := traceEvent(traceCallOne, "running")
	start["query"] = "budget OR notes"
	if _, err := traceRecord(t, f, start); err != nil {
		t.Fatal(err)
	}
	done := traceEvent(strings.ToUpper(traceCallOne), "succeeded")
	done["quantity"] = 2
	got, err := traceRecord(t, f, done)
	if err != nil || !strings.Contains(got, "budget OR notes") {
		t.Fatal("terminal lost start preview", err)
	}
	if _, err = traceRecord(t, f, done); err != nil {
		t.Fatal("same terminal not idempotent", err)
	}
	if _, err = traceRecord(t, f, start); err == nil {
		t.Fatal("terminal downgraded to running")
	}
	rows, _ := f.store.run("SELECT payload FROM replica WHERE name=?", "m-"+storeToolTestQuestion)
	if len(rows) != 1 || rows[0] != got {
		t.Fatal("message/outbox diverged")
	}
}
func TestLocalToolTraceRedactsOnlyWhitelistedPreview(t *testing.T) {
	f := newStoreToolFixture(t, false)
	start := traceEvent(traceCallOne, "running")
	start["query"] = "预算 https://user:pass@example.invalid/path?access_token=synthetic-secret www.example.invalid/signed?key=secret Bearer abcdefghijklmnopqrstuvwxyz sk-proj-0123456789abcdefghijklmnop"
	got, err := traceRecord(t, f, start)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"example.invalid", "synthetic-secret", "abcdefghijklmnopqrstuvwxyz", "sk-proj-012"} {
		if strings.Contains(got, secret) {
			t.Fatal("unsafe preview persisted")
		}
	}
	if !strings.Contains(got, "预算") || !strings.Contains(got, "[omitted]") {
		t.Fatal("useful preview dropped")
	}
	bad := traceEvent(traceCallTwo, "running")
	bad["arguments"] = map[string]any{"key": "synthetic"}
	if _, err = traceRecord(t, f, bad); err == nil {
		t.Fatal("unknown raw arguments accepted")
	}
}
func TestLocalToolTraceHeaderLifecycle(t *testing.T) {
	f := newStoreToolFixture(t, false)
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	delete(h, "replyAttempts")
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	raw, _ := f.store.Snapshot()
	if !strings.Contains(raw, `"state":"interrupted"`) {
		t.Fatal("terminal attempt left running trace")
	}
}

func traceStored(t *testing.T, s *LocalStore, c, m string) localToolTrace {
	t.Helper()
	rows, err := s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", m, c)
	if err != nil || len(rows) != 1 {
		t.Fatal("trace message missing", err)
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal([]byte(rows[0]), &fields)
	trace, err := decodeLocalToolTrace(fields["localToolTrace"])
	if err != nil {
		t.Fatal(err)
	}
	return trace
}
func traceScope(f storeToolFixture, request string, event any) map[string]any {
	return map[string]any{"conversation_id": storeToolTestConversation, "user_message_id": storeToolTestQuestion, "request_id": request, "expected_bot": f.bot, "event": event}
}
func traceDirect(t *testing.T, f storeToolFixture, scope any) (string, error) {
	t.Helper()
	return any(f.store).(breadcrumbRecorder).RecordConversationToolBreadcrumb(storeToolTestJSON(t, scope))
}

func TestLocalToolTraceStrictEventAndAllMessageEntrypoints(t *testing.T) {
	invalid := []map[string]any{}
	for _, change := range []map[string]any{{"arguments": map[string]any{"key": "synthetic"}}, {"output": "synthetic answer"}, {"query": nil}, {"queryTruncated": true}, {"quantity": 1}, {"failure": "timeout"}, {"function": "shell"}, {"function": "create_skill", "skillName": "INVALID"}, {"function": "create_skill", "query": "bad"}, {"state": "partial", "quantity": 1}, {"state": "failed", "failure": "raw provider error"}, {"state": "succeeded", "quantity": 31}, {"state": "succeeded", "quantity": 1.5}} {
		event := traceEvent(traceCallOne, "running")
		for k, v := range change {
			event[k] = v
		}
		invalid = append(invalid, event)
	}
	f := newStoreToolFixture(t, false)
	before, _ := f.store.Snapshot()
	for i, event := range invalid {
		if _, err := traceRecord(t, f, event); err == nil {
			t.Fatalf("invalid event accepted %d", i)
		}
		storedEvent := map[string]any{}
		for k, v := range event {
			storedEvent[k] = v
		}
		storedEvent["sequence"] = 0
		trace := map[string]any{"version": 1, "runRevision": "1000000000000000000", "requestID": storeToolTestRequest, "entries": []any{storedEvent}}
		message := map[string]any{"id": "77777777-7777-4777-8777-000000000001", "role": "user", "content": "synthetic imported", "localToolTrace": trace}
		header := deletionSnapshotHeader(t, f.store, storeToolTestConversation)
		if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), storeToolTestJSON(t, message)); err == nil {
			t.Fatalf("local append accepted invalid trace %d", i)
		}
		record := replicaRecord{Name: "m-77777777-7777-4777-8777-000000000001", Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: storeToolTestJSON(t, message)}
		if err := f.store.ApplyReplica(storeToolTestJSON(t, record)); err == nil {
			t.Fatalf("replica accepted invalid trace %d", i)
		}
		if _, err := f.store.NeedsReplicaPayload(storeToolTestJSON(t, record)); err == nil {
			t.Fatalf("replica payload gate accepted invalid trace %d", i)
		}
	}
	after, _ := f.store.Snapshot()
	if after != before {
		t.Fatal("invalid trace changed history")
	}
}

func TestLocalToolTracePreviewSanitizesBeforeClipping(t *testing.T) {
	f := newStoreToolFixture(t, false)
	for i, secret := range []string{"Authorization: Bearer synthetic-private-value-12345", "authorization=synthetic-private-value-12345", `"api_key":"synthetic-private-value-12345"`, "access_token=Bearer synthetic-private-value-12345", "Authorization: Basic synthetic-private-value-12345", "access_token='synthetic-private-value-12345'", "password=synthetic-private-value-12345", "www.example.invalid/signed?token=synthetic-private-value-12345"} {
		e := traceEvent(fmt.Sprintf("abcdef12-abcd-4abc-8abc-%012d", i+1), "running")
		e["query"] = "正常词 " + secret + " " + strings.Repeat("绿", 300)
		got, err := traceRecord(t, f, e)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(got, "synthetic-private-value") || strings.Contains(got, "example.invalid") {
			t.Fatal("redaction left credential suffix")
		}
	}
	trace := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	for _, e := range trace.Entries {
		if e.Query == nil || len([]rune(*e.Query)) > 256 || !strings.Contains(*e.Query, "正常词") || e.QueryTruncated == nil || !*e.QueryTruncated {
			t.Fatal("preview clipping or provenance failed")
		}
	}
	e := traceEvent(traceCallTwo, "running")
	e["query"] = strings.Repeat("x", 1025)
	e["queryTruncated"] = true
	if _, err := traceRecord(t, f, e); err != nil {
		t.Fatal(err)
	}
	trace = traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	last := trace.Entries[len(trace.Entries)-1]
	if last.Query != nil || last.QueryTruncated != nil {
		t.Fatal("over-bound query retained prefix")
	}
}

func TestLocalToolTraceOriginalBotHashChainAllowsOwnSkill(t *testing.T) {
	f := newStoreToolFixture(t, true)
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	f.create(t, "synthetic-own-skill")
	done := traceEvent(traceCallOne, "succeeded")
	done["quantity"] = 1
	if _, err := traceRecord(t, f, done); err != nil {
		t.Fatal("own skill update broke original chain", err)
	}
	current := storeToolTestHeader(t, f.store, storeToolTestConversation)
	changed := traceScope(f, storeToolTestRequest, traceEvent(traceCallTwo, "running"))
	changed["expected_bot"] = current["bot"]
	if _, err := traceDirect(t, f, changed); err == nil {
		t.Fatal("caller replaced original bot anchor")
	}
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(current["bot"], &bot)
	bot["futureNonsecretField"] = json.RawMessage(`{"changed":true}`)
	current["bot"] = json.RawMessage(storeToolTestJSON(t, bot))
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, current), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := traceRecord(t, f, traceEvent(traceCallTwo, "running")); err == nil {
		t.Fatal("external bot replacement accepted")
	}
}

func TestLocalToolTraceNewAttemptWithoutToolsResetsLatestRun(t *testing.T) {
	f := newStoreToolFixture(t, false)
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	done := traceEvent(traceCallOne, "succeeded")
	done["quantity"] = 0
	if _, err := traceRecord(t, f, done); err != nil {
		t.Fatal(err)
	}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	const next = "11111111-1111-4111-8111-000000000088"
	h["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": next, "userMessageID": storeToolTestQuestion, "phase": "preparing"}}))
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	rows, _ := f.store.run("SELECT payload FROM message WHERE id=?", storeToolTestQuestion)
	reset := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	if reset.RequestID != next || len(reset.Entries) != 0 {
		t.Fatal("new no-tool attempt failed empty run barrier")
	}
	_ = rows
	if _, err := traceRecord(t, f, traceEvent(traceCallTwo, "running")); err == nil {
		t.Fatal("old request still records")
	}
	if _, err := traceDirect(t, f, traceScope(f, next, traceEvent(traceCallTwo, "running"))); err != nil {
		t.Fatal(err)
	}
}

func TestLocalToolTraceFinishOnlyInterruptsRunning(t *testing.T) {
	for _, phase := range []string{"failed", "interrupted", "complete"} {
		t.Run(phase, func(t *testing.T) {
			f := newStoreToolFixture(t, false)
			if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
				t.Fatal(err)
			}
			done := traceEvent(traceCallOne, "succeeded")
			done["quantity"] = 2
			if _, err := traceRecord(t, f, done); err != nil {
				t.Fatal(err)
			}
			if _, err := traceRecord(t, f, traceEvent(traceCallTwo, "running")); err != nil {
				t.Fatal(err)
			}
			h := storeToolTestHeader(t, f.store, storeToolTestConversation)
			if phase == "complete" {
				delete(h, "replyAttempts")
			} else {
				h["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": storeToolTestRequest, "userMessageID": storeToolTestQuestion, "phase": phase}}))
			}
			if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
				t.Fatal(err)
			}
			trace := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
			if trace.Entries[0].State != "succeeded" || trace.Entries[1].State != "interrupted" {
				t.Fatal("parent terminal misreported tool outcome")
			}
		})
	}
}

func TestLocalToolTraceStartupPreservesOtherConnectionActiveOwner(t *testing.T) {
	f := newStoreToolFixture(t, false)
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	second, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	if traceStored(t, second, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "running" {
		t.Fatal("open guessed other window was dead")
	}
	second.Close()
	if _, err = f.store.run("UPDATE conversation SET header=json_remove(header,'$.replyAttempts') WHERE id=?", storeToolTestConversation); err != nil {
		t.Fatal(err)
	}
	third, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close()
	if traceStored(t, third, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "interrupted" {
		t.Fatal("durable inactive owner not recovered")
	}
	rows, _ := third.run("SELECT key FROM metadata WHERE key>=? AND key<?", toolTraceActivePrefix, strings.TrimSuffix(toolTraceActivePrefix, ":")+";")
	if len(rows) != 0 {
		t.Fatal("terminal ownership index retained")
	}
}

func TestLocalToolTraceForeignRemoteRunningNotInterruptedLocally(t *testing.T) {
	f := newStoreToolFixture(t, false)
	const other = "77777777-7777-4777-8777-000000000077"
	trace := map[string]any{"version": 1, "runRevision": "1000000000000000000", "requestID": "88888888-8888-4888-8888-000000000088", "entries": []any{map[string]any{"sequence": 0, "id": traceCallOne, "function": "search_chat_history", "state": "running", "query": "safe https://example.invalid/?key=synthetic-secret"}}}
	record := replicaRecord{Name: "m-" + other, Kind: "message", Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: storeToolTestJSON(t, map[string]any{"id": other, "role": "user", "content": "synthetic foreign", "localToolTrace": trace})}
	if err := f.store.ApplyReplica(storeToolTestJSON(t, record)); err != nil {
		t.Fatal(err)
	}
	if needed, err := f.store.NeedsReplicaPayload(storeToolTestJSON(t, record)); err != nil || !needed {
		t.Fatal("canonical replay cannot repair files", err)
	}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	h["title"] = json.RawMessage(`"rename only"`)
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	second, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	got := traceStored(t, second, storeToolTestConversation, other)
	if got.Entries[0].State != "running" || strings.Contains(*got.Entries[0].Query, "example.invalid") {
		t.Fatal("foreign live state guessed or unsafe preview retained")
	}
}

func TestLocalToolTraceConcurrentCallsAndLimit(t *testing.T) {
	f := newStoreToolFixture(t, false)
	second, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	var wg sync.WaitGroup
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			store := f.store
			if index%2 != 0 {
				store = second
			}
			e := traceEvent(fmt.Sprintf("abcdef12-abcd-4abc-8abc-%012d", index+1), "running")
			input := storeToolTestJSON(t, traceScope(f, storeToolTestRequest, e))
			_, err := any(store).(breadcrumbRecorder).RecordConversationToolBreadcrumb(input)
			errs <- err
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion).Entries) != 16 {
		t.Fatal("concurrent updates lost entries")
	}
	for i := 16; i < 64; i++ {
		if _, err := traceRecord(t, f, traceEvent(fmt.Sprintf("abcdef12-abcd-4abc-8abc-%012d", i+1), "running")); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := traceRecord(t, f, traceEvent("abcdef12-abcd-4abc-8abc-000000000099", "running")); err == nil {
		t.Fatal("call limit exceeded")
	}
	for i := 15; i >= 0; i-- {
		event := traceEvent(fmt.Sprintf("abcdef12-abcd-4abc-8abc-%012d", i+1), "succeeded")
		event["quantity"] = i % 3
		if _, err := traceRecord(t, f, event); err != nil {
			t.Fatal(err)
		}
	}
	got := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	for i := 0; i < 16; i++ {
		if got.Entries[i].State != "succeeded" {
			t.Fatal("same-name reverse completion mismatched")
		}
	}
}

func TestLocalToolTraceImportedCopyInterruptsRunningAndRejectsAssistantTrace(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	trace := map[string]any{"version": 1, "runRevision": "1000000000000000000", "requestID": storeToolTestRequest, "entries": []any{map[string]any{"sequence": 0, "id": traceCallOne, "function": "search_chat_history", "state": "running"}}}
	message := map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "synthetic imported", "localToolTrace": trace}
	docs := []any{map[string]any{"id": storeToolTestConversation, "title": "restored", "messages": []any{message}}}
	if err = store.RestoreCopies(storeToolTestJSON(t, docs), "[]"); err != nil {
		t.Fatal(err)
	}
	if traceStored(t, store, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "interrupted" {
		t.Fatal("copy resumed old tool")
	}
	message["role"] = "assistant"
	message["id"] = "77777777-7777-4777-8777-000000000099"
	header := deletionSnapshotHeader(t, store, storeToolTestConversation)
	if err = store.Update(storeToolTestConversation, storeToolTestJSON(t, header), storeToolTestJSON(t, message)); err == nil {
		t.Fatal("assistant accepted user-owned trace")
	}
}

func TestLocalToolTracePartialImagesAndFixedErrors(t *testing.T) {
	f := newStoreToolFixture(t, false)
	start := map[string]any{"id": traceCallOne, "function": "send_images", "state": "running"}
	if _, err := traceRecord(t, f, start); err != nil {
		t.Fatal(err)
	}
	done := map[string]any{"id": traceCallOne, "function": "send_images", "state": "partial", "quantity": 1}
	if _, err := traceRecord(t, f, done); err != nil {
		t.Fatal(err)
	}
	failed := traceEvent(traceCallTwo, "running")
	if _, err := traceRecord(t, f, failed); err != nil {
		t.Fatal(err)
	}
	failed["state"] = "failed"
	failed["failure"] = "timeout"
	if _, err := traceRecord(t, f, failed); err != nil {
		t.Fatal(err)
	}
	next := traceEvent("abcdef12-abcd-4abc-8abc-000000000099", "succeeded")
	if _, err := traceRecord(t, f, next); err == nil {
		t.Fatal("terminal call with no observed start accepted")
	}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	delete(h, "replyAttempts")
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	got := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	if got.Entries[0].State != "partial" || got.Entries[1].State != "failed" || *got.Entries[1].Failure != "timeout" {
		t.Fatal("parent completion changed actual tool outcomes")
	}
}

func TestLocalToolTraceDeletionAndStaleHistoryRejectLateMetadata(t *testing.T) {
	f := newStoreToolFixture(t, false)
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	const answer = "77777777-7777-4777-8777-000000000012"
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), storeToolTestJSON(t, map[string]any{"id": answer, "role": "assistant", "content": "synthetic earlier"})); err != nil {
		t.Fatal(err)
	}
	if err := f.store.DeleteMessage(storeToolTestConversation, answer); err != nil {
		t.Fatal(err)
	}
	if traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "interrupted" {
		t.Fatal("changed history left live call")
	}
	rows, _ := f.store.run("SELECT key FROM metadata WHERE key>=? AND key<?", toolTraceActivePrefix, strings.TrimSuffix(toolTraceActivePrefix, ":")+";")
	if len(rows) != 0 {
		t.Fatal("deletion retained owner")
	}
	fresh := deletionSnapshotHeader(t, f.store, storeToolTestConversation)
	const next = "88888888-8888-4888-8888-000000000001"
	fresh["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": next, "userMessageID": storeToolTestQuestion, "phase": "submitted"}}))
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, fresh), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := traceDirect(t, f, traceScope(f, next, traceEvent(traceCallTwo, "running"))); err == nil || err.Error() != "stale_conversation_history" {
		t.Fatal("stale epoch metadata accepted", err)
	}
	scope := traceScope(f, next, traceEvent(traceCallTwo, "running"))
	scope["history_revision"] = json.RawMessage(fresh["historyRevision"])
	if _, err := traceDirect(t, f, scope); err != nil {
		t.Fatal(err)
	}
	if err := f.store.DeleteMessage(storeToolTestConversation, storeToolTestQuestion); err != nil {
		t.Fatal(err)
	}
	if _, err := traceDirect(t, f, scope); err == nil {
		t.Fatal("deleted parent metadata revived")
	}
	raw, _ := f.store.Snapshot()
	if strings.Contains(raw, "localToolTrace") {
		t.Fatal("trace survived parent tombstone")
	}
}

func TestLocalToolTraceUUIDCaseResolutionAndBackupRoundTrip(t *testing.T) {
	const chat = "abcdef12-abcd-4abc-8abc-abcdef123450"
	const message = "abcdef12-abcd-4abc-8abc-abcdef123451"
	const request = "abcdef12-abcd-4abc-8abc-abcdef123452"
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	data := []any{map[string]any{"id": chat, "title": "synthetic lowercase", "replyAttempts": []any{map[string]any{"id": request, "userMessageID": message, "phase": "submitted"}}, "messages": []any{map[string]any{"id": message, "role": "user", "content": "synthetic body"}}}}
	if err = store.Insert(storeToolTestJSON(t, data), false); err != nil {
		t.Fatal(err)
	}
	input := map[string]any{"conversation_id": strings.ToUpper(chat), "user_message_id": strings.ToUpper(message), "request_id": strings.ToUpper(request), "expected_bot": nil, "event": traceEvent(strings.ToUpper(traceCallOne), "running")}
	if _, err = any(store).(breadcrumbRecorder).RecordConversationToolBreadcrumb(storeToolTestJSON(t, input)); err != nil {
		t.Fatal("Swift uppercase failed", err)
	}
	input["event"] = map[string]any{"id": traceCallOne, "function": "search_chat_history", "state": "succeeded", "quantity": 0}
	if _, err = any(store).(breadcrumbRecorder).RecordConversationToolBreadcrumb(storeToolTestJSON(t, input)); err != nil {
		t.Fatal(err)
	}
	snapshot, _ := store.Snapshot()
	manifest := `{"version":2,"conversations":` + snapshot + `}`
	archive := filepath.Join(t.TempDir(), "safe.aauvbackup")
	if err = WriteBackupZIP(archive, t.TempDir(), manifest); err != nil {
		t.Fatal(err)
	}
	read, err := ReadBackupZIP(archive, t.TempDir())
	if err != nil || read != manifest {
		t.Fatal("safe trace backup changed", err)
	}
	var decoded struct {
		Conversations json.RawMessage `json:"conversations"`
	}
	_ = json.Unmarshal([]byte(read), &decoded)
	target, err := OpenLocalStore(filepath.Join(t.TempDir(), "restored.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	// Independent restore has no live attempt. Preserve completed tool history.
	var copies []map[string]json.RawMessage
	_ = json.Unmarshal(decoded.Conversations, &copies)
	delete(copies[0], "replyAttempts")
	if err = target.RestoreCopies(storeToolTestJSON(t, copies), "[]"); err != nil {
		t.Fatal(err)
	}
	got := traceStored(t, target, chat, message)
	if got.RequestID != request || got.Entries[0].State != "succeeded" {
		t.Fatal("backup lost canonical terminal history")
	}
}

func TestLocalToolTraceMalformedEnvelopeRejectedOnInsert(t *testing.T) {
	for _, raw := range []string{`null`, `{"version":2,"requestID":"` + storeToolTestRequest + `","entries":[]}`, `{"version":1,"requestID":"` + storeToolTestRequest + `","entries":null}`, `{"version":1,"requestID":"` + storeToolTestRequest + `","entries":[],"raw":"secret"}`, `{"version":1,"version":1,"requestID":"` + storeToolTestRequest + `","entries":[]}`} {
		store, err := OpenLocalStore(filepath.Join(t.TempDir(), "synthetic.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		message := map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "synthetic", "localToolTrace": json.RawMessage(raw)}
		if err = store.Insert(storeToolTestJSON(t, []any{map[string]any{"id": storeToolTestConversation, "messages": []any{message}}}), false); err == nil {
			store.Close()
			t.Fatal("malformed envelope imported")
		}
		snapshot, _ := store.Snapshot()
		store.Close()
		if snapshot != "[]" {
			t.Fatal("malformed import was not atomic")
		}
	}
}

func TestLocalToolTraceLongBotScopeDoesNotConsumeMetadataLimit(t *testing.T) {
	f := newStoreToolFixture(t, true)
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(h["bot"], &bot)
	var instructions map[string]json.RawMessage
	_ = json.Unmarshal(bot["instructions"], &instructions)
	instructions["prompt"] = json.RawMessage(storeToolTestJSON(t, strings.Repeat("synthetic local prompt ", 8000)))
	bot["instructions"] = json.RawMessage(storeToolTestJSON(t, instructions))
	h["bot"] = json.RawMessage(storeToolTestJSON(t, bot))
	f.bot = h["bot"]
	if len(f.bot) <= localToolTraceLimit || len(f.bot) >= 512*1024 {
		t.Fatal("fixture not within real prompt scope")
	}
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal("legitimate scope prompt hit metadata cap", err)
	}
	rows, _ := f.store.run("SELECT value FROM metadata WHERE key LIKE 'conversation_tool_%'")
	if strings.Contains(strings.Join(rows, ""), "synthetic local prompt") {
		t.Fatal("scope prompt leaked into metadata")
	}
}

func TestLocalToolTraceInvisibleCredentialPrefixAndWrongOwner(t *testing.T) {
	f := newStoreToolFixture(t, false)
	start := traceEvent(traceCallOne, "running")
	start["query"] = "keep Author\u200bization: Bearer synthetic-private-value-12345 https\u200b://example.invalid/signed?key=synthetic-private-value-12345"
	got, err := traceRecord(t, f, start)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got, "synthetic-private-value") || strings.Contains(got, "example.invalid") || !strings.Contains(got, "keep") {
		t.Fatal("invisible prefix bypassed preview redaction")
	}
	h := storeToolTestHeader(t, f.store, storeToolTestConversation)
	h["localToolTrace"] = json.RawMessage(`{"raw":"synthetic forbidden"}`)
	if err = f.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err == nil {
		t.Fatal("trace at header owner accepted")
	}
	record := replicaRecord{Name: "c-" + storeToolTestConversation, Kind: "conversation", Conversation: storeToolTestConversation, Revision: "8000000000000000000", Payload: storeToolTestJSON(t, h)}
	if err = f.store.ApplyReplica(storeToolTestJSON(t, record)); err == nil {
		t.Fatal("remote trace at header owner accepted")
	}
}

func TestLocalToolTraceCanonicalPipelineControlsAndIdempotence(t *testing.T) {
	for _, query := range []string{"Bearer\x00SYNTHETIC_SECRET", "Bearer\u00a0SYNTHETIC_SECRET", "Authorization\x00:\x00Bearer\x00SYNTHETIC_SECRET", "https://example.invalid/path\x00SYNTHETIC_SECRET"} {
		preview, _ := traceQuery(query)
		if strings.Contains(preview, "SYNTHETIC_SECRET") || strings.Contains(preview, "example.invalid") {
			t.Errorf("normalization exposed redacted span")
		}
	}
	query := strings.Repeat("a ", 129)
	first, err := canonicalTraceEntry(localToolTraceEntry{ID: traceCallOne, Function: "search_chat_history", State: "running", Query: &query})
	if err != nil {
		t.Fatal(err)
	}
	second, err := canonicalTraceEntry(first)
	if err != nil {
		t.Fatal(err)
	}
	a, _ := json.Marshal(first)
	b, _ := json.Marshal(second)
	if string(a) != string(b) {
		t.Fatal("canonical(canonical(x)) differs from canonical(x)")
	}
	if first.Query == nil || strings.HasSuffix(*first.Query, " ") || first.QueryTruncated == nil || !*first.QueryTruncated {
		t.Fatal("clipped query must be trimmed and marked truncated")
	}
}
