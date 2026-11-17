package aauvcore

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

const botFixture = `{"id":"D7224BF2-660B-4F56-B9F9-2EDE4EB82C6D","configuration":{"name":"研究","endpoint":"https://api.example/v1","model":"example","loginMethod":"byok","apiProtocol":"responses","instructions":{"prompt":"简洁","skills":"## 笔记"}}}`

func TestCopilotProfileAllowsRuntimeDefaultModel(t *testing.T) {
	blank := strings.Replace(botFixture, `"model":"example"`, `"model":""`, 1)
	if _, err := validateBotProfile(blank); err == nil {
		t.Fatal("BYOK must still require a model")
	}
	copilot := strings.Replace(blank, `"loginMethod":"byok"`, `"loginMethod":"copilot"`, 1)
	profile, err := validateBotProfile(copilot)
	if err != nil || profile.Configuration.Model != "" {
		t.Fatal("Copilot profile should be able to use the runtime default", err)
	}
}

func TestBotReplicationAndDeletedProfile(t *testing.T) {
	open := func(name string) *LocalStore {
		t.Helper()
		store, err := OpenLocalStore(filepath.Join(t.TempDir(), name))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(store.Close)
		return store
	}
	source, target := open("source.db"), open("target.db")
	if err := source.SaveBots("[" + botFixture + "]"); err != nil {
		t.Fatal(err)
	}
	pending, err := source.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	var records []json.RawMessage
	if err = json.Unmarshal([]byte(pending), &records); err != nil || len(records) != 1 {
		t.Fatal("expected bot record", err)
	}
	original := string(records[0])
	if err = target.ApplyReplica(original); err != nil {
		t.Fatal(err)
	}
	snapshot, err := target.Bots()
	if err != nil || !strings.Contains(snapshot, "## 笔记") {
		t.Fatal("bot content not replicated", err)
	}
	echo, err := target.PendingReplica()
	if err != nil || echo != "[]" {
		t.Fatal("replica echoed an unchanged bot", err)
	}
	id := "D7224BF2-660B-4F56-B9F9-2EDE4EB82C6D"
	if err = target.DeleteBot(id); err != nil {
		t.Fatal(err)
	}
	if err = target.ApplyReplica(original); err != nil {
		t.Fatal(err)
	}
	snapshot, err = target.Bots()
	if err != nil || snapshot != "[]" {
		t.Fatal("deleted bot reappeared", err)
	}
	if err = target.SaveBots("[" + botFixture + "]"); err == nil {
		t.Fatal("stale editor recreated deleted bot")
	}
}

func TestRestoreBotAndConversationAtomicity(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const chat = `[{"id":"chat","title":"原始会话","messages":[]}]`
	invalid := strings.Replace(botFixture, `"name":"研究"`, `"name":"研究","key":"must-not-sync"`, 1)
	if err = store.RestoreCopies(chat, "["+invalid+"]"); err == nil {
		t.Fatal("archive accepted a key in bot metadata")
	}
	snapshot, err := store.Snapshot()
	if err != nil || snapshot != "[]" {
		t.Fatal("failed restore partially saved a conversation", err)
	}
	if err = store.RestoreCopies(chat, "["+botFixture+"]"); err != nil {
		t.Fatal(err)
	}
	snapshot, err = store.Snapshot()
	if err != nil || !strings.Contains(snapshot, "原始会话") {
		t.Fatal("valid restore lost conversation", err)
	}
	bots, err := store.Bots()
	if err != nil || !strings.Contains(bots, "研究") {
		t.Fatal("valid restore lost robot", err)
	}
}

func TestRestoreNamedSkillsAndValidateIncomingRecords(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "skills.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const entry = `{"id":"D7224BF2-660B-4F56-B9F9-2EDE4EB82C6D","name":"笔记","markdown":"整理笔记","enabled":false}`
	const valid = `{"prompt":"研究","skills":"","skillEntries":[` + entry + `]}`
	for _, invalid := range []string{
		`{"prompt":"","skills":"","skillEntries":[` + entry + "," + strings.ToLower(entry) + `]}`,
		strings.Replace(valid, `"enabled":false`, `"enabled":null`, 1),
		strings.Replace(valid, `"enabled":false`, `"enabled":false,"token":"no"`, 1),
		strings.Replace(valid, "整理笔记", strings.Repeat("x", 512*1024), 1),
	} {
		if err := store.SetInstructions(invalid); err == nil {
			t.Fatal("accepted malformed named skill")
		}
	}
	const chat = `[{"id":"chat","title":"会话","messages":[]}]`
	if err := store.RestoreCopiesWithInstructions(chat, "[{}]", valid); err == nil {
		t.Fatal("accepted malformed robot")
	}
	raw, err := store.Instructions()
	if err != nil || raw != "" {
		t.Fatal("failed restore changed shared instructions", err)
	}
	raw, err = store.Snapshot()
	if err != nil || raw != "[]" {
		t.Fatal("failed restore wrote conversation", err)
	}
	bot := strings.Replace(botFixture, `{"prompt":"简洁","skills":"## 笔记"}`, valid, 1)
	if err := store.RestoreCopiesWithInstructions(chat, "["+bot+"]", valid); err != nil {
		t.Fatal(err)
	}
	raw, err = store.Instructions()
	if err != nil || raw != valid {
		t.Fatal("restore lost shared instructions", err)
	}
	raw, err = store.Bots()
	if err != nil || !strings.Contains(raw, entry) {
		t.Fatal("restore lost bot skills", err)
	}
}

func TestReportedUsageStaysLocalAndGroupsByPurpose(t *testing.T) {
	store, err := OpenLocalStore(filepath.Join(t.TempDir(), "usage.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	for _, purpose := range []string{"reply", "reply", "compression", "title"} {
		if err = store.RecordUsage("byok", "test", purpose, 9, 3); err != nil {
			t.Fatal(err)
		}
	}
	if err = store.RecordUsage("byok", "test", "reply", -1, 3); err == nil {
		t.Fatal("accepted negative usage")
	}
	raw, err := store.Usage()
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Purpose                 string
		Requests, Input, Output int
	}
	if err = json.Unmarshal([]byte(raw), &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 3 || rows[0].Purpose != "reply" || rows[0].Requests != 2 || rows[0].Input != 18 || rows[0].Output != 6 ||
		rows[1].Purpose != "compression" || rows[1].Requests != 1 || rows[2].Purpose != "title" || rows[2].Requests != 1 {
		t.Fatal("wrong usage aggregation", rows)
	}
	replica, err := store.PendingReplica()
	if err != nil || replica != "[]" {
		t.Fatal("usage was added to sync outbox", err)
	}
}
