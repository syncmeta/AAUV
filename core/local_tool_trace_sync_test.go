package aauvcore

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

const traceSyncReply = "99999999-9999-4999-8999-000000000001"

func traceSyncRecord(t *testing.T, s *LocalStore, name string) replicaRecord {
	t.Helper()
	rows, err := s.run("SELECT "+replicaJSON+" FROM replica WHERE name=?", name)
	if err != nil || len(rows) != 1 {
		t.Fatal("missing sync record", err)
	}
	var r replicaRecord
	if json.Unmarshal([]byte(rows[0]), &r) != nil {
		t.Fatal("invalid record")
	}
	return r
}
func traceSyncPeer(t *testing.T, source *LocalStore) *LocalStore {
	t.Helper()
	s, err := OpenLocalStore(filepath.Join(t.TempDir(), "peer.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	raw, err := source.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	var records []replicaRecord
	_ = json.Unmarshal([]byte(raw), &records)
	for _, r := range records {
		if err = s.ApplyReplica(storeToolTestJSON(t, r)); err != nil {
			t.Fatal(err)
		}
	}
	return s
}
func traceSyncFixture(t *testing.T) (storeToolFixture, *LocalStore, replicaRecord, replicaRecord) {
	t.Helper()
	a := newStoreToolFixture(t, false)
	h := storeToolTestHeader(t, a.store, storeToolTestConversation)
	if err := a.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), storeToolTestJSON(t, map[string]any{"id": traceSyncReply, "role": "assistant", "content": "synthetic reply", "replyTo": storeToolTestQuestion})); err != nil {
		t.Fatal(err)
	}
	if _, err := traceRecord(t, a, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	b := traceSyncPeer(t, a.store)
	done := traceEvent(traceCallOne, "succeeded")
	done["quantity"] = 2
	if _, err := traceRecord(t, a, done); err != nil {
		t.Fatal(err)
	}
	terminal := traceSyncRecord(t, a.store, "m-"+storeToolTestQuestion)
	if _, err := b.SetReplyChoice(storeToolTestConversation, storeToolTestQuestion, traceSyncReply); err != nil {
		t.Fatal(err)
	}
	newerBody := traceSyncRecord(t, b, "m-"+storeToolTestQuestion)
	if newerBody.Revision <= terminal.Revision {
		t.Fatal("fixture did not make newer body")
	}
	return a, b, terminal, newerBody
}
func TestLocalToolTraceSyncKeepsTerminalWhenNewerBodyArrives(t *testing.T) {
	a, b, _, newerBody := traceSyncFixture(t)
	if err := a.store.ApplyReplica(storeToolTestJSON(t, newerBody)); err != nil {
		t.Fatal(err)
	}
	got := traceStored(t, a.store, storeToolTestConversation, storeToolTestQuestion)
	if got.Entries[0].State != "succeeded" {
		t.Fatal("newer selection snapshot downgraded terminal to running")
	}
	merged := traceSyncRecord(t, a.store, "m-"+storeToolTestQuestion)
	if !strings.Contains(merged.Payload, traceSyncReply) {
		t.Fatal("trace merge lost newer reply choice")
	}
	if err := b.ApplyReplica(storeToolTestJSON(t, merged)); err != nil {
		t.Fatal(err)
	}
	if traceStored(t, b, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "succeeded" {
		t.Fatal("other peer did not converge")
	}
}
func TestLocalToolTraceSyncOlderBodyStillContributesTerminalOnly(t *testing.T) {
	a, b, terminal, _ := traceSyncFixture(t)
	needed, err := b.NeedsReplicaPayload(storeToolTestJSON(t, terminal))
	if err != nil || needed {
		t.Fatal("old body must not authorize copying attachments", err)
	}
	accepted, err := b.ApplyReplicaChecked(storeToolTestJSON(t, terminal))
	if err != nil || !accepted {
		t.Fatal("older body failed metadata-only improvement", err)
	}
	got := traceStored(t, b, storeToolTestConversation, storeToolTestQuestion)
	if got.Entries[0].State != "succeeded" {
		t.Fatal("older body terminal was lost")
	}
	current := traceSyncRecord(t, b, "m-"+storeToolTestQuestion)
	if !strings.Contains(current.Payload, traceSyncReply) {
		t.Fatal("metadata-only merge replaced newer choice")
	}
	if err = a.store.ApplyReplica(storeToolTestJSON(t, current)); err != nil {
		t.Fatal(err)
	}
	if traceStored(t, a.store, storeToolTestConversation, storeToolTestQuestion).Entries[0].State != "succeeded" {
		t.Fatal("reverse order did not converge")
	}
}

func TestLocalToolTraceSyncNewEmptyRunBlocksLateOldRun(t *testing.T) {
	a, b, terminal, _ := traceSyncFixture(t)
	h := deletionSnapshotHeader(t, a.store, storeToolTestConversation)
	const next = "88888888-8888-4888-8888-000000000099"
	h["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": next, "userMessageID": storeToolTestQuestion, "phase": "preparing"}}))
	prior := traceSyncRecord(t, a.store, "m-"+storeToolTestQuestion)
	if err := a.store.Update(storeToolTestConversation, storeToolTestJSON(t, h), ""); err != nil {
		t.Fatal(err)
	}
	reset := traceStored(t, a.store, storeToolTestConversation, storeToolTestQuestion)
	if reset.RequestID != next || reset.RunRevision <= prior.Revision || len(reset.Entries) != 0 {
		t.Fatal("reset did not mint a Core Lamport barrier")
	}
	resetRecord := traceSyncRecord(t, a.store, "m-"+storeToolTestQuestion)
	if err := b.ApplyReplica(storeToolTestJSON(t, resetRecord)); err != nil {
		t.Fatal(err)
	}
	if _, err := b.ApplyReplicaChecked(storeToolTestJSON(t, terminal)); err != nil {
		t.Fatal(err)
	}
	afterOld := traceStored(t, b, storeToolTestConversation, storeToolTestQuestion)
	if afterOld.RequestID != next || len(afterOld.Entries) != 0 {
		t.Fatal("late old run improved reset")
	}
	// A newer body revision carrying the OLD run still cannot erase the barrier.
	terminal.Revision = "8000000000000000000"
	if err := b.ApplyReplica(storeToolTestJSON(t, terminal)); err != nil {
		t.Fatal(err)
	}
	got := traceStored(t, b, storeToolTestConversation, storeToolTestQuestion)
	if got.RequestID != next || len(got.Entries) != 0 {
		t.Fatal("newer old-run snapshot revived old tools")
	}
	getter, err := a.store.ConversationMessage(storeToolTestConversation, storeToolTestQuestion)
	if err != nil || !strings.Contains(getter, reset.RunRevision) {
		t.Fatal("targeted getter missed Core reset", err)
	}
	input := traceScope(a, next, traceEvent(traceCallTwo, "running"))
	input["runRevision"] = "9000000000000000000"
	if _, err = traceDirect(t, a, input); err == nil {
		t.Fatal("caller chose a run clock")
	}
	e := traceEvent(traceCallTwo, "running")
	e["sequence"] = 0
	input = traceScope(a, next, e)
	if _, err = traceDirect(t, a, input); err == nil {
		t.Fatal("caller chose sequence")
	}
}

func TestLocalToolTraceSyncRealStartOrderSurvivesInverseUUIDs(t *testing.T) {
	f := newStoreToolFixture(t, false)
	const first = "ffffffff-ffff-4fff-8fff-ffffffffffff"
	const second = "00000000-0000-4000-8000-000000000001"
	if _, err := traceRecord(t, f, traceEvent(first, "running")); err != nil {
		t.Fatal(err)
	}
	if _, err := traceRecord(t, f, traceEvent(second, "running")); err != nil {
		t.Fatal(err)
	}
	trace := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	if trace.Entries[0].ID != first || trace.Entries[0].Sequence != 0 || trace.Entries[1].ID != second || trace.Entries[1].Sequence != 1 {
		t.Fatal("UUID sort replaced actual start order")
	}
	peer := traceSyncPeer(t, f.store)
	roundtrip := traceStored(t, peer, storeToolTestConversation, storeToolTestQuestion)
	if roundtrip.Entries[0].ID != first || roundtrip.Entries[1].ID != second {
		t.Fatal("replay changed actual start order")
	}
}

func TestLocalToolTraceSyncStaleBodyCannotReplaceAttachmentReferences(t *testing.T) {
	_, b, terminal, _ := traceSyncFixture(t)
	const currentFile = "abababab-abab-4aba-8aba-abababababab"
	const oldFile = "cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd"
	var fields map[string]json.RawMessage
	_ = json.Unmarshal([]byte(traceSyncRecord(t, b, "m-"+storeToolTestQuestion).Payload), &fields)
	fields["attachments"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"fileName": currentFile, "size": 3, "name": "current"}}))
	if err := b.transaction(true, func() error {
		_, err := b.writeMessageFields(storeToolTestConversation, storeToolTestQuestion, fields)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	_ = json.Unmarshal([]byte(terminal.Payload), &fields)
	fields["attachments"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"fileName": oldFile, "size": 3, "name": "old"}}))
	terminal.Payload = storeToolTestJSON(t, fields)
	if needed, err := b.NeedsReplicaPayload(storeToolTestJSON(t, terminal)); err != nil || needed {
		t.Fatal("stale attachments became eligible", err)
	}
	if accepted, err := b.ApplyReplicaChecked(storeToolTestJSON(t, terminal)); err != nil || !accepted {
		t.Fatal("safe trace did not merge", err)
	}
	current := traceSyncRecord(t, b, "m-"+storeToolTestQuestion)
	if !strings.Contains(current.Payload, currentFile) || strings.Contains(current.Payload, oldFile) || !strings.Contains(current.Payload, traceSyncReply) {
		t.Fatal("metadata-only merge replaced body/files/choice")
	}
	var traceFields map[string]json.RawMessage
	_ = json.Unmarshal([]byte(current.Payload), &traceFields)
	if !strings.Contains(string(traceFields["localToolTrace"]), "succeeded") {
		t.Fatal("terminal not kept")
	}
}

func TestLocalToolTraceSyncConflictingTerminalsConverge(t *testing.T) {
	a, b, terminal, newerBody := traceSyncFixture(t)
	var fields map[string]json.RawMessage
	_ = json.Unmarshal([]byte(newerBody.Payload), &fields)
	trace, err := decodeLocalToolTrace(fields["localToolTrace"])
	if err != nil {
		t.Fatal(err)
	}
	trace.Entries[0].State = "failed"
	failure := "timeout"
	trace.Entries[0].Failure = &failure
	trace.Entries[0].Quantity = nil
	fields["localToolTrace"], _ = encodeLocalToolTrace(trace)
	failed := newerBody
	failed.Revision = "8000000000000000000"
	failed.Payload = storeToolTestJSON(t, fields)
	if err = a.store.ApplyReplica(storeToolTestJSON(t, failed)); err != nil {
		t.Fatal(err)
	}
	if err = b.ApplyReplica(storeToolTestJSON(t, failed)); err != nil {
		t.Fatal(err)
	}
	if needed, err := b.NeedsReplicaPayload(storeToolTestJSON(t, terminal)); err != nil || needed {
		t.Fatal("older terminal body unexpectedly eligible", err)
	}
	if _, err = b.ApplyReplicaChecked(storeToolTestJSON(t, terminal)); err != nil {
		t.Fatal(err)
	}
	left := traceStored(t, a.store, storeToolTestConversation, storeToolTestQuestion)
	right := traceStored(t, b, storeToolTestConversation, storeToolTestQuestion)
	x, _ := encodeLocalToolTrace(left)
	y, _ := encodeLocalToolTrace(right)
	if string(x) != string(y) || left.Entries[0].State != "succeeded" {
		t.Fatal("conflicting terminal join depended on arrival order")
	}
}

func TestLocalToolTraceSyncLocalInsertWithActiveAttemptHasEmptyBarrier(t *testing.T) {
	f := newStoreToolFixture(t, false)
	initial := traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion)
	if initial.RequestID != strings.ToLower(storeToolTestRequest) || !validTraceRevision(initial.RunRevision) || len(initial.Entries) != 0 {
		t.Fatal("inserted live no-tool run lacked barrier")
	}
	firstClock := initial.RunRevision
	if _, err := traceRecord(t, f, traceEvent(traceCallOne, "running")); err != nil {
		t.Fatal(err)
	}
	if traceStored(t, f.store, storeToolTestConversation, storeToolTestQuestion).RunRevision != firstClock {
		t.Fatal("first tool changed initialized run clock")
	}
}
