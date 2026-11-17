package aauvcore

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestLegacyMigrationAndReplicaMerge(t *testing.T) {
	open := func(name string) *LocalStore {
		db, err := OpenLocalStore(filepath.Join(t.TempDir(), name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		return db
	}
	pending := func(db *LocalStore) []replicaRecord {
		t.Helper()
		raw, err := db.PendingReplica()
		if err != nil {
			t.Fatal(err)
		}
		var records []replicaRecord
		if err = json.Unmarshal([]byte(raw), &records); err != nil {
			t.Fatal(err)
		}
		return records
	}
	apply := func(db *LocalStore, record replicaRecord) {
		t.Helper()
		raw, _ := json.Marshal(record)
		if err := db.ApplyReplica(string(raw)); err != nil {
			t.Fatal(err)
		}
	}
	snapshot := func(db *LocalStore) string {
		t.Helper()
		raw, err := db.Snapshot()
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}

	a, b := open("a.db"), open("b.db")
	initial := `[{"id":"chat","title":"一","messages":[{"id":"first","role":"user","content":"原始消息","date":1}]}]`
	if err := a.Insert(initial, true); err != nil {
		t.Fatal(err)
	}
	if err := a.Insert(initial, true); err != nil {
		t.Fatal("repeat import", err)
	}
	records := pending(a)
	if len(records) != 2 {
		t.Fatal("expected a header and a message", len(records))
	}
	// A message can arrive before its header.
	apply(b, records[1])
	if snapshot(b) != "[]" {
		t.Fatal("orphan message became visible")
	}
	apply(b, records[0])
	apply(b, records[1])
	if !strings.Contains(snapshot(b), "原始消息") || len(pending(b)) != 0 {
		t.Fatal("remote state was lost or echoed")
	}
	if err := a.Update("chat", `{"id":"chat","title":"一","replyAttempts":[{"partial":"local-only"}]}`,
		`{"id":"second","role":"assistant","content":"来自 A","date":2}`); err != nil {
		t.Fatal(err)
	}
	if err := b.Update("chat", `{"id":"chat","title":"一"}`,
		`{"id":"third","role":"user","content":"来自 B","date":3}`); err != nil {
		t.Fatal(err)
	}
	for _, r := range pending(a) {
		apply(b, r)
	}
	for _, r := range pending(b) {
		apply(a, r)
	}
	for _, db := range []*LocalStore{a, b} {
		text := snapshot(db)
		if !strings.Contains(text, "来自 A") || !strings.Contains(text, "来自 B") {
			t.Fatal("concurrent messages did not merge")
		}
	}
	if strings.Contains(snapshot(b), "local-only") {
		t.Fatal("partial draft was synced")
	}
	if err := a.Delete("chat"); err != nil {
		t.Fatal(err)
	}
	for _, r := range pending(a) {
		apply(b, r)
	}
	for _, r := range records {
		apply(b, r)
	}
	if snapshot(b) != "[]" {
		t.Fatal("deleted conversation was resurrected")
	}
}

func TestLegacyMigrationRollsBackOnDuplicate(t *testing.T) {
	db, err := OpenLocalStore(filepath.Join(t.TempDir(), "db.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err = db.Insert(`[{"id":"same","messages":[]},{"id":"same","messages":[]}]`, true); err == nil {
		t.Fatal("duplicate import succeeded")
	}
	migrated, err := db.LegacyImported()
	if err != nil || migrated {
		t.Fatal("failed import marked as complete", err)
	}
	raw, err := db.Snapshot()
	if err != nil || raw != "[]" {
		t.Fatal("failed import wrote partial rows", err)
	}
}

func TestReplicaMessageRevisionUpdatesLocalHistory(t *testing.T) {
	path := filepath.Join(t.TempDir(), "messages.db")
	store, err := OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	other, err := OpenLocalStore(filepath.Join(t.TempDir(), "other.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()

	header := replicaRecord{Name: "c-chat", Kind: "conversation", Conversation: "chat",
		Revision: "0000000000000000001", Payload: `{"id":"chat"}`}
	first := replicaRecord{Name: "m-first", Kind: "message", Conversation: "chat",
		Revision: "0000000000000000002", Payload: `{"id":"first","role":"user","content":"old body","date":1}`}
	updated := first
	updated.Revision = "0000000000000000003"
	updated.Payload = `{"id":"first","role":"user","content":"new body","date":1}`
	encode := func(record replicaRecord) string {
		raw, _ := json.Marshal(record)
		return string(raw)
	}
	apply := func(db *LocalStore, records ...replicaRecord) {
		t.Helper()
		for _, record := range records {
			if err := db.ApplyReplica(encode(record)); err != nil {
				t.Fatal(err)
			}
		}
	}
	checkRevision := func(db *LocalStore) {
		t.Helper()
		snapshot, err := db.Snapshot()
		if err != nil || !strings.Contains(snapshot, "new body") || strings.Contains(snapshot, "old body") {
			t.Fatal("history did not converge", snapshot, err)
		}
		hits, err := db.SearchHistory("new body", "chat", "")
		if err != nil || !strings.Contains(hits, `"messageID":"first"`) {
			t.Fatal("search did not see the updated revision", hits, err)
		}
	}
	apply(store, header, first, updated, first)
	apply(other, updated, first, header)
	for _, db := range []*LocalStore{store, other} {
		checkRevision(db)
		if err := db.RequeueReplicaRecord(updated.Name); err != nil {
			t.Fatal(err)
		}
		pending, err := db.PendingReplica()
		var records []replicaRecord
		if err != nil || json.Unmarshal([]byte(pending), &records) != nil || len(records) != 1 || records[0] != updated {
			t.Fatal("requeue did not retain the displayed revision", pending, err)
		}
		apply(db, updated)
	}

	reassigned := updated
	reassigned.Conversation = "different-chat"
	reassigned.Revision = "0000000000000000004"
	if _, err := store.NeedsReplicaPayload(encode(reassigned)); err == nil {
		t.Fatal("a message must not be moved to a different conversation")
	}
	if err := store.ApplyReplica(encode(reassigned)); err == nil {
		t.Fatal("apply accepted a reassigned message")
	}

	// Reopen a database as left by the older code.
	if _, err := store.run("UPDATE message SET payload=? WHERE id='first'", first.Payload); err != nil {
		t.Fatal(err)
	}
	if _, err := store.run("DELETE FROM metadata WHERE key=?", replicaMessageRepair); err != nil {
		t.Fatal(err)
	}
	store.Close()
	reopened, err := OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	checkRevision(reopened)

	// Exact redelivery also repairs a divergent local row and acknowledges it.
	if _, err := reopened.run("UPDATE message SET payload=? WHERE id='first'", first.Payload); err != nil {
		t.Fatal(err)
	}
	apply(reopened, updated)
	checkRevision(reopened)
}

func TestPendingReplicaPagesSeparateReferencesFromExactRevisions(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "outbox.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	body := strings.Repeat("historical body ", 100000)
	if err := store.transaction(true, func() error {
		for _, name := range []string{"m-c", "m-a", "m-b"} {
			if err := store.stageRecordAt(name, "message", "chat", body, 1); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	type reference struct{ Name, Revision string }
	page := func(after reference) []reference {
		t.Helper()
		raw, err := store.PendingReplicaPage(after.Revision, after.Name, 2)
		var entries []reference
		if err != nil || len(raw) > 256 || json.Unmarshal([]byte(raw), &entries) != nil {
			t.Fatal("page should contain only small references", len(raw), err)
		}
		return entries
	}
	first := page(reference{})
	if len(first) != 2 || first[0].Name != "m-a" || first[1].Name != "m-b" {
		t.Fatal("incorrect order for records with the same revision", first)
	}
	second := page(first[1])
	if len(second) != 1 || second[0].Name != "m-c" || len(page(second[0])) != 0 {
		t.Fatal("keyset pagination skipped or repeated a record", second)
	}
	raw, err := store.PendingReplicaRecord(first[0].Name, first[0].Revision)
	var record replicaRecord
	if err != nil || json.Unmarshal([]byte(raw), &record) != nil || record.Payload != body {
		t.Fatal("exact revision did not load its body", err)
	}
	if err := store.transaction(true, func() error { return store.stageRecordAt("m-a", "message", "chat", "edited", 2) }); err != nil {
		t.Fatal(err)
	}
	if err := store.AcknowledgeReplica(first[0].Name, first[0].Revision); err != nil {
		t.Fatal(err)
	}
	if raw, err := store.PendingReplicaRecord(first[0].Name, first[0].Revision); err != nil || raw != "" {
		t.Fatal("obsolete revision remained eligible", err)
	}
	if revision, err := store.PendingReplicaRevision("m-a"); err != nil || revision <= first[0].Revision {
		t.Fatal("old acknowledgement cleared a newer edit", revision, err)
	}
	if err := store.AcknowledgeReplica(first[1].Name, first[1].Revision); err != nil {
		t.Fatal(err)
	}
	if count, err := store.PendingReplicaCount(); err != nil || count != 2 {
		t.Fatal("count must include only pending items", count, err)
	}
	if revision, err := store.PendingReplicaRevision("m-b"); err != nil || revision != "" {
		t.Fatal("acknowledged record is still pending", revision, err)
	}
	if _, err := store.PendingReplicaPage("", "", 513); err == nil {
		t.Fatal("accepted an unbounded page")
	}
}

func TestLegacyReplyChoiceMigratesWithoutReplacingNewerChoice(t *testing.T) {
	path := filepath.Join(t.TempDir(), "choices.db")
	open := func() *LocalStore {
		t.Helper()
		db, err := OpenLocalStore(path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(db.Close)
		return db
	}
	db := open()
	const chosen = "7B626B56-8D10-4A45-833C-97BE67F76E39"
	const input = `[{"id":"chat","selectedReplies":{"prompt":"` + chosen + `","later":"` + chosen + `"},"messages":[
		{"id":"prompt","role":"user","content":"keep the body","date":1},
		{"id":"original","role":"assistant","date":2},
		{"id":"later","role":"user","date":3,"selectedReplyID":"later-reply"},
		{"id":"later-reply","role":"assistant","replyTo":"later","date":4},
		{"id":"` + chosen + `","role":"assistant","replyTo":"prompt","date":5}
	]}]`
	if err := db.Insert(input, false); err != nil {
		t.Fatal(err)
	}
	if _, err := db.run("DELETE FROM metadata WHERE key=?", replyChoiceMigration); err != nil {
		t.Fatal(err)
	}
	db.Close()
	db = open()
	pending, err := db.PendingReplica()
	var records []replicaRecord
	if err != nil || json.Unmarshal([]byte(pending), &records) != nil {
		t.Fatal("invalid outbox", err)
	}
	for _, record := range records {
		var message struct{ Content, SelectedReplyID string }
		switch record.Name {
		case "m-prompt":
			if json.Unmarshal([]byte(record.Payload), &message) != nil || message.Content != "keep the body" || message.SelectedReplyID != chosen {
				t.Fatal("legacy choice and body were not preserved", record)
			}
		case "m-later":
			if json.Unmarshal([]byte(record.Payload), &message) != nil || message.SelectedReplyID != "later-reply" {
				t.Fatal("migration overwrote a current choice", record)
			}
		}
	}
	if _, err := db.SetReplyChoice("chat", "later", chosen); err == nil {
		t.Fatal("accepted a reply to another prompt")
	}
	payload, err := db.SetReplyChoice("chat", "prompt", "original")
	if err != nil || !strings.Contains(payload, `"selectedReplyID":"original"`) {
		t.Fatal("could not select an original reply without a stored parent ID", payload, err)
	}
	db.Close()
	snapshot, err := open().Snapshot()
	if err != nil || !strings.Contains(snapshot, `"selectedReplyID":"original"`) {
		t.Fatal("reopen did not retain the new choice", snapshot, err)
	}
}

func TestInstructionsFollowReplicaRevision(t *testing.T) {
	db, err := OpenLocalStore(filepath.Join(t.TempDir(), "instructions.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	const legacy = `{"prompt":"旧提示词","skills":"旧技能"}`
	const updated = `{"prompt":"新提示词","skills":"新技能"}`
	if err := db.SeedInstructions(legacy, 1000000000); err != nil {
		t.Fatal(err)
	}
	remote := replicaRecord{Name: instructionsRecord, Kind: "instructions", Revision: "0000000002000000000", Payload: updated}
	data, err := json.Marshal(remote)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.ApplyReplica(string(data)); err != nil {
		t.Fatal(err)
	}
	if err := db.SeedInstructions(legacy, 3000000000); err != nil {
		t.Fatal(err)
	}
	text, err := db.Instructions()
	if err != nil || text != updated {
		t.Fatal("replica did not supersede legacy file", err)
	}
	pending, err := db.PendingReplica()
	if err != nil || pending != "[]" {
		t.Fatal("remote instructions echoed as local change", err)
	}
	if err := db.SetInstructions(`{"prompt":"","skills":"","key":"synthetic"}`); err == nil {
		t.Fatal("instructions outbox accepted unsupported secret fields")
	}
	if err := db.SetInstructions(`{"prompt":"","skills":""}`); err != nil {
		t.Fatal(err)
	}
	pending, err = db.PendingReplica()
	if err != nil || !strings.Contains(pending, instructionsRecord) {
		t.Fatal("explicitly clearing instructions did not sync", err)
	}
}

func TestRebuildReplicaPreservesHistoryAndTombstones(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "source.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const data = `[{"id":"keep","title":"history","messages":[{"id":"first","content":"retained"}]},{"id":"remove","title":"deleted","messages":[{"id":"discard","content":"never reupload"}]}]`
	if err := store.Insert(data, true); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete("remove"); err != nil {
		t.Fatal(err)
	}
	if err := store.SetInstructions(`{"prompt":"local prompt","skills":""}`); err != nil {
		t.Fatal(err)
	}
	pending := func() []replicaRecord {
		t.Helper()
		value, err := store.PendingReplica()
		var records []replicaRecord
		if err != nil || json.Unmarshal([]byte(value), &records) != nil {
			t.Fatal("invalid pending replica", err)
		}
		return records
	}
	initial := pending()
	if len(initial) != 4 {
		t.Fatal("expected a header, a message, a tombstone and instructions", initial)
	}
	for _, record := range initial {
		if err := store.AcknowledgeReplica(record.Name, record.Revision); err != nil {
			t.Fatal(err)
		}
	}
	if len(pending()) != 0 {
		t.Fatal("test data should already be acknowledged")
	}

	if err := store.RequeueReplicaRecord("m-discard"); err != nil {
		t.Fatal(err)
	}
	if len(pending()) != 0 {
		t.Fatal("a locally deleted message was requeued")
	}
	if err := store.RequeueReplicaRecord("m-first"); err != nil {
		t.Fatal(err)
	}
	if records := pending(); len(records) != 1 || records[0].Name != "m-first" {
		t.Fatal("individual cloud deletion did not requeue only the affected record", records)
	}

	if err := store.RequeueReplica(); err != nil {
		t.Fatal(err)
	}
	rebuilt := pending()
	if len(rebuilt) != len(initial) {
		t.Fatal("restoring the cloud zone must include previously acknowledged records")
	}
	for i, record := range rebuilt {
		if record != initial[i] {
			t.Fatal("recovery changed a record or advanced its conflict revision")
		}
	}
	peer, err := OpenLocalStore(filepath.Join(t.TempDir(), "fresh-device.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	for _, record := range rebuilt {
		packet, _ := json.Marshal(record)
		if err := peer.ApplyReplica(string(packet)); err != nil {
			t.Fatal(err)
		}
		// If the replacement zone already contains an exact match, a fresh fetch acknowledges it.
		if err := store.ApplyReplica(string(packet)); err != nil {
			t.Fatal(err)
		}
	}
	snapshot, err := peer.Snapshot()
	if err != nil || !strings.Contains(snapshot, "retained") || strings.Contains(snapshot, "never reupload") {
		t.Fatal("restored zone did not reproduce the local conversation state", err)
	}
	if len(pending()) != 0 {
		t.Fatal("exact cloud matches stayed in the recovery outbox")
	}
}
