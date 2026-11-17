package aauvcore

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

const storeToolTestConversation = "11111111-1111-4111-8111-000000000001"
const storeToolTestQuestion = "11111111-1111-4111-8111-000000000002"
const storeToolTestRequest = "11111111-1111-4111-8111-000000000003"
const storeToolTestOtherConversation = "11111111-1111-4111-8111-000000000004"

type storeToolFixture struct {
	store *LocalStore
	path  string
	bot   json.RawMessage
}

func storeToolTestJSON(t *testing.T, value any) string {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

func storeToolTestDocument(t *testing.T, prompt, legacy, name string, number int) json.RawMessage {
	t.Helper()
	return json.RawMessage(storeToolTestJSON(t, map[string]any{"prompt": prompt, "skills": legacy,
		"skillEntries": []any{map[string]any{"id": fmt.Sprintf("22222222-2222-4222-8222-%012d", number),
			"name": name, "markdown": "retained markdown", "enabled": true}}}))
}

func newStoreToolFixture(t *testing.T, bound bool) storeToolFixture {
	t.Helper()
	path := filepath.Join(t.TempDir(), "synthetic.sqlite3")
	store, err := OpenLocalStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.Close)
	bot := json.RawMessage("null")
	if bound {
		bot = json.RawMessage(storeToolTestJSON(t, map[string]any{
			"name": "Synthetic bot", "endpoint": "https://chatgpt.com/backend-api", "model": "synthetic-model",
			"loginMethod": "chatgpt", "chatGPTClientID": "oaiapp_synthetic-binding", "apiProtocol": "responses",
			"profileID": "33333333-abcd-4abc-8abc-abcdef000001", "hostedTools": []string{"web_search"},
			"instructions":         storeToolTestDocument(t, "local prompt", "local legacy skills", "old-local", 2),
			"futureNonsecretField": map[string]any{"preserve": true},
		}))
	}
	header := map[string]any{
		"id": storeToolTestConversation, "title": "Retained synthetic title", "automaticTitle": true,
		"bot": bot, "compression": map[string]any{"preserve": "local compression"},
		"replyAttempts": []any{map[string]any{"id": storeToolTestRequest, "userMessageID": storeToolTestQuestion,
			"phase": "submitted", "partial": "retained partial", "regenerating": true}},
		"selectedReplies": map[string]string{"synthetic": "preserved"},
		"messages":        []any{map[string]any{"id": storeToolTestQuestion, "role": "user", "content": "current synthetic question", "date": 800000000}},
	}
	other := map[string]any{"id": storeToolTestOtherConversation, "title": "Other private title", "bot": bot,
		"messages": []any{map[string]any{"id": "11111111-1111-4111-8111-000000000005", "role": "user",
			"content": "OTHER_CONVERSATION_PRIVATE synthetic hidden content", "date": 800000001}}}
	if err = store.Insert(storeToolTestJSON(t, []any{header, other}), false); err != nil {
		t.Fatal(err)
	}
	if err = store.SetInstructions(string(storeToolTestDocument(t, "global prompt", "global legacy skills", "old-global", 1))); err != nil {
		t.Fatal(err)
	}
	profile := map[string]any{"id": "33333333-3333-4333-8333-000000000009", "configuration": map[string]any{
		"name": "Unchanged saved bot", "endpoint": "https://fixture.invalid/v1", "model": "fixture", "loginMethod": "byok"}}
	if err = store.SaveBots(storeToolTestJSON(t, []any{profile})); err != nil {
		t.Fatal(err)
	}
	return storeToolFixture{store: store, path: path, bot: bot}
}

func (f storeToolFixture) input(t *testing.T, call, name string, arguments any) string {
	t.Helper()
	return storeToolTestJSON(t, storeToolInput{ConversationID: storeToolTestConversation, UserMessageID: storeToolTestQuestion,
		RequestID: storeToolTestRequest, CallID: call, Name: name, Arguments: json.RawMessage(storeToolTestJSON(t, arguments)), ExpectedBot: f.bot})
}

func (f storeToolFixture) create(t *testing.T, call string) string {
	t.Helper()
	result, err := f.store.ExecuteConversationTool(f.input(t, call, "create_skill", map[string]any{
		"name": "synthetic-skill", "description": "Synthetic description", "body": "# Body\nKeep this body exactly.\n"}))
	if err != nil || strings.Contains(result, `"error"`) {
		t.Fatalf("create failed: %s %v", result, err)
	}
	return result
}

func storeToolTestHeader(t *testing.T, store *LocalStore, id string) map[string]json.RawMessage {
	t.Helper()
	rows, err := store.run("SELECT header FROM conversation WHERE id=?", id)
	if err != nil || len(rows) != 1 {
		t.Fatalf("missing synthetic header: %v", err)
	}
	var header map[string]json.RawMessage
	if err = json.Unmarshal([]byte(rows[0]), &header); err != nil {
		t.Fatal(err)
	}
	return header
}

func storeToolTestState(t *testing.T, store *LocalStore) string {
	t.Helper()
	conversations, err := store.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	instructions, err := store.Instructions()
	if err != nil {
		t.Fatal(err)
	}
	bots, err := store.Bots()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := store.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	metadata, err := store.run("SELECT json_array(key,value) FROM metadata WHERE key LIKE 'conversation_tool_%' ORDER BY key")
	if err != nil {
		t.Fatal(err)
	}
	return storeToolTestJSON(t, []any{conversations, instructions, bots, pending, metadata})
}

func storeToolTestRecords(t *testing.T, store *LocalStore) []replicaRecord {
	t.Helper()
	text, err := store.PendingReplica()
	if err != nil {
		t.Fatal(err)
	}
	var records []replicaRecord
	if err = json.Unmarshal([]byte(text), &records); err != nil {
		t.Fatal(err)
	}
	return records
}

func storeToolTestAcknowledge(t *testing.T, store *LocalStore) {
	t.Helper()
	for _, record := range storeToolTestRecords(t, store) {
		if err := store.AcknowledgeReplica(record.Name, record.Revision); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLocalStoreToolCreatesSkillLocallyAndReplays(t *testing.T) {
	f := newStoreToolFixture(t, true)
	before := storeToolTestHeader(t, f.store, storeToolTestConversation)
	beforeOther := storeToolTestHeader(t, f.store, storeToolTestOtherConversation)
	beforeBots, _ := f.store.Bots()
	storeToolTestAcknowledge(t, f.store)
	result := f.create(t, "call-create")
	var created struct {
		SkillID    string `json:"skill_id"`
		Subscribed bool   `json:"subscribed"`
	}
	if json.Unmarshal([]byte(result), &created) != nil || !validNodeUUID(created.SkillID) || !created.Subscribed {
		t.Fatal("invalid creation result")
	}
	globalJSON, _ := f.store.Instructions()
	var global botInstructions
	if json.Unmarshal([]byte(globalJSON), &global) != nil || len(global.SkillEntries) != 2 ||
		*global.Prompt != "global prompt" || *global.Skills != "global legacy skills" ||
		!*global.SkillEntries[0].Enabled || *global.SkillEntries[1].Enabled {
		t.Fatal("global library lost content or globally enabled the new skill")
	}
	if global.SkillEntries[1].Markdown != "Synthetic description\n\n# Body\nKeep this body exactly.\n" {
		t.Fatal("description/body were not preserved")
	}
	after := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(after["bot"], &bot)
	var local botInstructions
	_ = json.Unmarshal(bot["instructions"], &local)
	if len(local.SkillEntries) != 2 || local.SkillEntries[0].Name != "old-local" ||
		local.SkillEntries[1].ID != created.SkillID || !*local.SkillEntries[1].Enabled ||
		*local.Prompt != "local prompt" || *local.Skills != "local legacy skills" {
		t.Fatal("conversation-specific instructions were replaced or disabled")
	}
	var originalBot map[string]json.RawMessage
	_ = json.Unmarshal(f.bot, &originalBot)
	delete(bot, "instructions")
	delete(originalBot, "instructions")
	if storeToolTestJSON(t, bot) != storeToolTestJSON(t, originalBot) {
		t.Fatal("bot identity, credentials binding or other fields changed")
	}
	delete(before, "bot")
	delete(after, "bot")
	afterBots, _ := f.store.Bots()
	if storeToolTestJSON(t, before) != storeToolTestJSON(t, after) || beforeBots != afterBots ||
		storeToolTestJSON(t, beforeOther) != storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestOtherConversation)) {
		t.Fatal("unrelated headers/bots changed")
	}
	records := storeToolTestRecords(t, f.store)
	if len(records) != 2 {
		t.Fatal("expected exactly library/chat outbox updates", len(records))
	}
	for _, record := range records {
		if record.Kind != "instructions" && record.Kind != "conversation" {
			t.Fatal("unexpected replicated state")
		}
		if strings.Contains(record.Payload, "replyAttempts") || strings.Contains(record.Payload, "conversation_tool_") {
			t.Fatal("local execution state leaked into replication")
		}
	}
	stable := storeToolTestState(t, f.store)
	if f.create(t, "call-create") != result || storeToolTestState(t, f.store) != stable {
		t.Fatal("same call created another skill or modified revisions")
	}
	var reordered storeToolInput
	_ = json.Unmarshal([]byte(f.input(t, "call-create", "create_skill", map[string]any{})), &reordered)
	reordered.Arguments = json.RawMessage(`{ "name":"synthetic-skill", "body":"# Body\nKeep this body exactly.\n", "description":"Synthetic description" }`)
	if replay, err := f.store.ExecuteConversationTool(storeToolTestJSON(t, reordered)); err != nil || replay != result || storeToolTestState(t, f.store) != stable {
		t.Fatal("object key order/whitespace changed replay identity", err)
	}
	// Same original expected_bot is accepted after this request's own update.
	search, err := f.store.ExecuteConversationTool(f.input(t, "call-search-after-create", "search_chat_history", map[string]any{"query": "synthetic"}))
	if err != nil || !strings.Contains(search, "current synthetic question") {
		t.Fatal("request's own bot-hash chain was rejected", err)
	}
	f.create(t, "call-second-create")
	globalJSON, _ = f.store.Instructions()
	_ = json.Unmarshal([]byte(globalJSON), &global)
	if len(global.SkillEntries) != 3 || *global.SkillEntries[1].Enabled || *global.SkillEntries[2].Enabled {
		t.Fatal("a second call did not incrementally merge into the library")
	}
	stable = storeToolTestState(t, f.store)
	conflict := f.input(t, "call-create", "create_skill", map[string]any{"name": "different", "body": "changed"})
	if _, err = f.store.ExecuteConversationTool(conflict); err == nil || err.Error() != "conversation_tool_call_conflict" || storeToolTestState(t, f.store) != stable {
		t.Fatal("same call with changed arguments was not rejected atomically", err)
	}
	f.store.Close()
	reopened, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	f.store = reopened
	if f.create(t, "call-create") != result {
		t.Fatal("receipt did not survive reopening the local database")
	}
}

func TestLocalStoreToolDoesNotDuplicateGlobalInstructionsWhenLocalAbsent(t *testing.T) {
	f := newStoreToolFixture(t, true)
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(f.bot, &bot)
	delete(bot, "instructions")
	f.bot = json.RawMessage(storeToolTestJSON(t, bot))
	header["bot"] = f.bot
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err != nil {
		t.Fatal(err)
	}
	f.create(t, "inherit")
	header = storeToolTestHeader(t, f.store, storeToolTestConversation)
	_ = json.Unmarshal(header["bot"], &bot)
	var local botInstructions
	_ = json.Unmarshal(bot["instructions"], &local)
	if *local.Prompt != "" || *local.Skills != "" || len(local.SkillEntries) != 1 ||
		local.SkillEntries[0].Name != "synthetic-skill" || !*local.SkillEntries[0].Enabled {
		t.Fatal("global instructions were copied into the local document")
	}
	globalJSON, _ := f.store.Instructions()
	var global botInstructions
	_ = json.Unmarshal([]byte(globalJSON), &global)
	render := func(doc botInstructions) string {
		parts := []string{*doc.Prompt, *doc.Skills}
		for _, skill := range doc.SkillEntries {
			if *skill.Enabled {
				parts = append(parts, "### "+skill.Name+"\n"+skill.Markdown)
			}
		}
		return strings.Join(parts, "\n\n")
	}
	// Matches the app's global.requestInstructions + bot.requestInstructions
	// composition: global prompt/legacy text/enabled skills are present once.
	effective := render(global) + "\n\n" + render(local)
	if strings.Count(effective, "global prompt") != 1 || strings.Count(effective, "global legacy skills") != 1 ||
		strings.Count(effective, "### old-global\n") != 1 || strings.Count(effective, "### synthetic-skill\n") != 1 {
		t.Fatal("next-turn composition duplicated or lost global instructions or the new local skill")
	}
}

func TestLocalStoreToolMatchesOptionalNilsWithoutDroppingStoredFields(t *testing.T) {
	f := newStoreToolFixture(t, true)
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(f.bot, &bot)
	delete(bot, "profileID")
	f.bot = json.RawMessage(storeToolTestJSON(t, bot))
	bot["profileID"] = json.RawMessage("null")
	header["bot"] = json.RawMessage(storeToolTestJSON(t, bot))
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err != nil {
		t.Fatal(err)
	}
	f.create(t, "optional-nil")
	header = storeToolTestHeader(t, f.store, storeToolTestConversation)
	_ = json.Unmarshal(header["bot"], &bot)
	if string(bot["profileID"]) != "null" {
		t.Fatal("matching an optional nil erased an unrelated stored field")
	}
}

func TestLocalStoreToolAcceptsSwiftUUIDReencodingWithinRequest(t *testing.T) {
	f := newStoreToolFixture(t, true)
	f.create(t, "before-swift-reencode")
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(header["bot"], &bot)
	var profile string
	_ = json.Unmarshal(bot["profileID"], &profile)
	bot["profileID"] = json.RawMessage(storeToolTestJSON(t, strings.ToUpper(profile)))
	var instructions botInstructions
	_ = json.Unmarshal(bot["instructions"], &instructions)
	for i := range instructions.SkillEntries {
		instructions.SkillEntries[i].ID = strings.ToUpper(instructions.SkillEntries[i].ID)
	}
	bot["instructions"] = json.RawMessage(storeToolTestJSON(t, instructions))
	header["bot"] = json.RawMessage(storeToolTestJSON(t, bot))
	// Swift reloadReplica + saveAttempt re-encodes UUID properties in uppercase.
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err != nil {
		t.Fatal(err)
	}
	search, err := f.store.ExecuteConversationTool(f.input(t, "after-swift-reencode", "search_chat_history", map[string]any{"query": "synthetic"}))
	if err != nil || !strings.Contains(search, "current synthetic question") {
		t.Fatal("Swift's known-UUID spelling changed request identity", err)
	}
	f.create(t, "create-after-swift-reencode")
}

func TestLocalStoreToolCapacityFailurePreservesBothDocuments(t *testing.T) {
	f := newStoreToolFixture(t, true)
	header := storeToolTestHeader(t, f.store, storeToolTestConversation)
	var bot map[string]json.RawMessage
	_ = json.Unmarshal(f.bot, &bot)
	bot["instructions"] = json.RawMessage(storeToolTestJSON(t, map[string]any{"prompt": strings.Repeat("x", 512*1024), "skills": ""}))
	f.bot = json.RawMessage(storeToolTestJSON(t, bot))
	header["bot"] = f.bot
	if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err != nil {
		t.Fatal(err)
	}
	beforeHeader := storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestConversation))
	beforeLibrary, _ := f.store.Instructions()
	storeToolTestAcknowledge(t, f.store)
	result, err := f.store.ExecuteConversationTool(f.input(t, "capacity", "create_skill", map[string]any{"name": "bounded-skill", "body": "synthetic body"}))
	afterLibrary, _ := f.store.Instructions()
	pending, _ := f.store.PendingReplicaCount()
	if err != nil || !strings.Contains(result, `"error"`) || beforeLibrary != afterLibrary || pending != 0 ||
		beforeHeader != storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestConversation)) {
		t.Fatal("capacity failure changed existing instructions or outbox", err)
	}
}

func TestLocalStoreToolRollbackCoversSkillHeaderOutboxAndReceipt(t *testing.T) {
	for _, failure := range []string{"conversation", "receipt"} {
		t.Run(failure, func(t *testing.T) {
			f := newStoreToolFixture(t, true)
			trigger := `CREATE TEMP TRIGGER reject_tool_write BEFORE INSERT ON replica WHEN NEW.name='c-` + storeToolTestConversation + `' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;`
			if failure == "receipt" {
				trigger = `CREATE TEMP TRIGGER reject_tool_write BEFORE INSERT ON metadata WHEN NEW.key LIKE 'conversation_tool_receipt:%' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;`
			}
			if err := f.store.exec(trigger); err != nil {
				t.Fatal(err)
			}
			before := storeToolTestState(t, f.store)
			input := f.input(t, "rollback", "create_skill", map[string]any{"name": "rollback-skill", "body": "synthetic body"})
			if _, err := f.store.ExecuteConversationTool(input); err == nil || storeToolTestState(t, f.store) != before {
				t.Fatal("transaction failure partially committed a skill, header, outbox or receipt", err)
			}
			if err := f.store.exec("DROP TRIGGER reject_tool_write"); err != nil {
				t.Fatal(err)
			}
			if _, err := f.store.ExecuteConversationTool(input); err != nil {
				t.Fatal("rollback prevented a valid retry", err)
			}
		})
	}
}

func TestLocalStoreToolConcurrentReplayAcrossConnections(t *testing.T) {
	f := newStoreToolFixture(t, true)
	other, err := OpenLocalStore(f.path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	input := f.input(t, "concurrent", "create_skill", map[string]any{"name": "concurrent-skill", "body": "synthetic body"})
	const workers = 16
	results := make(chan string, workers)
	errors := make(chan error, workers)
	var group sync.WaitGroup
	for i := range workers {
		group.Add(1)
		go func() {
			defer group.Done()
			store := f.store
			if i%2 != 0 {
				store = other
			}
			result, err := store.ExecuteConversationTool(input)
			results <- result
			errors <- err
		}()
	}
	group.Wait()
	close(results)
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	var prior string
	for result := range results {
		if prior != "" && prior != result {
			t.Fatal("concurrent identical calls produced different receipts")
		}
		prior = result
	}
	text, _ := f.store.Instructions()
	var library botInstructions
	_ = json.Unmarshal([]byte(text), &library)
	if len(library.SkillEntries) != 2 {
		t.Fatal("concurrent replay duplicated a skill")
	}
}

func TestLocalStoreToolRejectsStaleOrDeletedContext(t *testing.T) {
	for _, change := range []string{"bot", "credential-binding", "credential-binding-case", "instructions", "failed", "interrupted", "ended", "question", "conversation", "different-question", "two-active"} {
		t.Run(change, func(t *testing.T) {
			f := newStoreToolFixture(t, true)
			f.create(t, "old-receipt")
			header := storeToolTestHeader(t, f.store, storeToolTestConversation)
			switch change {
			case "bot", "credential-binding", "credential-binding-case", "instructions":
				var bot map[string]json.RawMessage
				_ = json.Unmarshal(header["bot"], &bot)
				field, value := "name", `"another bot"`
				if change == "credential-binding" {
					field, value = "chatGPTClientID", `"oaiapp_another-synthetic-account"`
				} else if change == "credential-binding-case" {
					field, value = "chatGPTClientID", `"oaiapp_Synthetic-binding"`
				} else if change == "instructions" {
					field, value = "instructions", `{"prompt":"edited","skills":""}`
				}
				bot[field] = json.RawMessage(value)
				header["bot"] = json.RawMessage(storeToolTestJSON(t, bot))
			case "failed", "interrupted":
				header["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": storeToolTestRequest, "userMessageID": storeToolTestQuestion, "phase": change}}))
			case "ended":
				delete(header, "replyAttempts")
			case "different-question":
				header["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{map[string]any{"id": storeToolTestRequest, "userMessageID": "11111111-1111-4111-8111-000000000099", "phase": "submitted"}}))
			case "two-active":
				header["replyAttempts"] = json.RawMessage(storeToolTestJSON(t, []any{
					map[string]any{"id": storeToolTestRequest, "userMessageID": storeToolTestQuestion, "phase": "submitted"},
					map[string]any{"id": "11111111-1111-4111-8111-000000000098", "userMessageID": storeToolTestQuestion, "phase": "preparing"}}))
			case "question":
				if _, err := f.store.run("DELETE FROM message WHERE id=?", storeToolTestQuestion); err != nil {
					t.Fatal(err)
				}
			case "conversation":
				if err := f.store.Delete(storeToolTestConversation); err != nil {
					t.Fatal(err)
				}
			}
			if change != "conversation" {
				if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, header), ""); err != nil {
					t.Fatal(err)
				}
			}
			before := storeToolTestState(t, f.store)
			for _, call := range []string{"old-receipt", "new-call"} {
				if _, err := f.store.ExecuteConversationTool(f.input(t, call, "create_skill", map[string]any{
					"name": "synthetic-skill", "description": "Synthetic description", "body": "# Body\nKeep this body exactly.\n"})); err == nil {
					t.Fatal("stale context executed or returned a cached receipt")
				}
			}
			if storeToolTestState(t, f.store) != before {
				t.Fatal("stale context changed the database")
			}
		})
	}
}

func TestLocalStoreToolNullBotAndArgumentFailures(t *testing.T) {
	f := newStoreToolFixture(t, false)
	result, err := f.store.ExecuteConversationTool(f.input(t, "null-create", "create_skill", map[string]any{"name": "valid-name", "body": "body"}))
	if err != nil || result != `{"error":"needs_bound_bot"}` {
		t.Fatal("null bot should not be silently bound", result, err)
	}
	result, err = f.store.ExecuteConversationTool(f.input(t, "null-search", "search_chat_history", map[string]any{"query": "current"}))
	if err != nil || !strings.Contains(result, "current synthetic question") {
		t.Fatal("null bot blocked scoped search", err)
	}
	result, err = f.store.ExecuteConversationTool(f.input(t, "unsupported", "execute_code", map[string]any{}))
	if err != nil || result != `{"error":"unsupported_tool"}` {
		t.Fatal("unsupported tool was not explicitly rejected")
	}
	bound := newStoreToolFixture(t, true)
	for i, args := range []any{
		map[string]any{}, map[string]any{"name": "Not-Kebab", "body": "body"},
		map[string]any{"name": strings.Repeat("a", 81), "body": "body"},
		map[string]any{"name": "valid", "description": strings.Repeat("中", 2001), "body": "body"},
		map[string]any{"name": "valid", "body": " \n "},
		map[string]any{"name": "valid", "body": strings.Repeat("中", 65537)},
		map[string]any{"name": "valid", "body": 42},
	} {
		before := storeToolTestHeader(t, bound.store, storeToolTestConversation)
		library, _ := bound.store.Instructions()
		result, err := bound.store.ExecuteConversationTool(bound.input(t, fmt.Sprint("bad", i), "create_skill", args))
		afterLibrary, _ := bound.store.Instructions()
		if err != nil || !strings.Contains(result, `"error"`) || library != afterLibrary ||
			storeToolTestJSON(t, before) != storeToolTestJSON(t, storeToolTestHeader(t, bound.store, storeToolTestConversation)) {
			t.Fatal("invalid skill argument changed content", err)
		}
	}
	for _, input := range []string{`{}`, `{"arguments":[]}`, strings.Repeat(" ", storeToolInputLimit+1)} {
		if _, err := bound.store.ExecuteConversationTool(input); err == nil {
			t.Fatal("invalid input envelope executed")
		}
	}
}

func TestLocalStoreToolReplicatesOnlyLibraryAndCurrentBot(t *testing.T) {
	f := newStoreToolFixture(t, true)
	remote, err := OpenLocalStore(filepath.Join(t.TempDir(), "other-device.sqlite3"))
	if err != nil {
		t.Fatal(err)
	}
	defer remote.Close()
	apply := func() {
		for _, record := range storeToolTestRecords(t, f.store) {
			if err := remote.ApplyReplica(storeToolTestJSON(t, record)); err != nil {
				t.Fatal(err)
			}
			if err := f.store.AcknowledgeReplica(record.Name, record.Revision); err != nil {
				t.Fatal(err)
			}
		}
	}
	apply()
	f.create(t, "replicated-skill")
	apply()
	localLibrary, _ := f.store.Instructions()
	remoteLibrary, _ := remote.Instructions()
	if localLibrary != remoteLibrary {
		t.Fatal("library did not replicate")
	}
	localHeader := storeToolTestHeader(t, f.store, storeToolTestConversation)
	remoteHeader := storeToolTestHeader(t, remote, storeToolTestConversation)
	if string(localHeader["bot"]) != string(remoteHeader["bot"]) || remoteHeader["replyAttempts"] != nil {
		t.Fatal("conversation skill/binding failed to replicate or local attempt leaked")
	}
	metadata, _ := remote.run("SELECT key FROM metadata WHERE key LIKE 'conversation_tool_%'")
	pending, _ := remote.PendingReplicaCount()
	if len(metadata) != 0 || pending != 0 {
		t.Fatal("local receipts replicated or remote changes echoed")
	}
	if _, err := remote.ExecuteConversationTool(f.input(t, "replicated-skill", "create_skill", map[string]any{"name": "synthetic-skill", "body": "body"})); err == nil {
		t.Fatal("another device accepted a request it did not begin")
	}
}

func TestLocalStoreToolSearchScopeOrderingAndFilters(t *testing.T) {
	f := newStoreToolFixture(t, true)
	base := time.Date(2026, 1, 2, 3, 4, 0, 0, time.UTC)
	date := func(i int) float64 { return float64(base.Add(time.Duration(i)*time.Second).Unix() - 978307200) }
	for i := range 40 {
		payload := map[string]any{"id": fmt.Sprintf("44444444-4444-4444-8444-%012d", i), "role": "user", "content": fmt.Sprintf("needle item %02d", i), "date": date(i)}
		if i%2 != 0 {
			payload["role"] = "assistant"
		}
		if i == 39 {
			payload["content"] = "needle " + strings.Repeat("🌱中", 300)
		}
		if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestConversation)), storeToolTestJSON(t, payload)); err != nil {
			t.Fatal(err)
		}
	}
	for i, payload := range []map[string]any{
		{"role": "log", "content": "needle hidden log", "date": date(100)},
		{"role": "user", "content": "needle recalled", "status": "deleted", "date": date(101)},
		{"role": "user", "content": nil, "date": date(102)},
		{"role": "user", "content": "unknown-date synthetic"},
		{"role": "user", "content": "unusable-date synthetic", "date": 999999999999},
	} {
		payload["id"] = fmt.Sprintf("55555555-5555-4555-8555-%012d", i)
		if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestConversation)), storeToolTestJSON(t, payload)); err != nil {
			t.Fatal(err)
		}
	}
	storeToolTestAcknowledge(t, f.store)
	type hit struct {
		When    *string `json:"when"`
		Speaker string  `json:"speaker"`
		Content string  `json:"content"`
	}
	search := func(call string, args any) []hit {
		t.Helper()
		result, err := f.store.ExecuteConversationTool(f.input(t, call, "search_chat_history", args))
		if err != nil || strings.Contains(result, `"error"`) || strings.Contains(result, "OTHER_CONVERSATION_PRIVATE") || strings.Contains(result, "oaiapp_") {
			t.Fatal("invalid or unscoped search result", err)
		}
		var decoded struct {
			Results []hit `json:"results"`
		}
		if err := json.Unmarshal([]byte(result), &decoded); err != nil {
			t.Fatal(err)
		}
		return decoded.Results
	}
	hits := search("default-limit", map[string]any{"query": "NEEDLE"})
	if len(hits) != 10 || hits[0].Content != "needle item 30" || hits[0].Speaker != "them" || hits[1].Speaker != "me" ||
		utf8.RuneCountInString(hits[9].Content) != 400 || !utf8.ValidString(hits[9].Content) {
		t.Fatal("latest limit, order, role or Unicode snippet differed")
	}
	hits = search("max-limit", map[string]any{"query": "needle", "limit": 1000})
	if len(hits) != 30 || hits[0].Content != "needle item 10" {
		t.Fatal("limit maximum was not enforced")
	}
	hits = search("time-window", map[string]any{"since": base.Add(10 * time.Second).Format(time.RFC3339),
		"until": base.Add(13 * time.Second).Format(time.RFC3339)})
	if len(hits) != 3 || hits[0].Content != "needle item 10" || hits[2].Content != "needle item 12" ||
		hits[0].When == nil || *hits[0].When != base.Add(10*time.Second).Format(time.RFC3339) {
		t.Fatal("half-open source-date bounds or Foundation date conversion differed")
	}
	hits = search("unknown-date", map[string]any{"query": "unknown-date"})
	if len(hits) != 1 || hits[0].When != nil {
		t.Fatal("unknown date was invented")
	}
	hits = search("unusable-date", map[string]any{"query": "unusable-date"})
	if len(hits) != 1 || hits[0].When != nil {
		t.Fatal("an out-of-range source date was formatted as a false RFC3339 timestamp")
	}
	if len(search("other-scope", map[string]any{"query": "OTHER_CONVERSATION_PRIVATE"})) != 0 {
		t.Fatal("another conversation was searched")
	}
	if len(search("bound-sql", map[string]any{"query": `"' OR 1=1 --"`})) != 0 {
		t.Fatal("query value altered SQL scope")
	}
	for i, args := range []any{map[string]any{}, map[string]any{"since": "not-a-date"},
		map[string]any{"until": "2026-99-99"}, map[string]any{"query": "foo OR"}, map[string]any{"query": `"unclosed`}} {
		result, err := f.store.ExecuteConversationTool(f.input(t, fmt.Sprint("invalid-search", i), "search_chat_history", args))
		if err != nil || !strings.Contains(result, `"error"`) {
			t.Fatal("invalid query did not return a correctable model error", err)
		}
	}
	pending, _ := f.store.PendingReplicaCount()
	if pending != 0 {
		t.Fatal("history search modified synchronized content")
	}
}

func TestLocalStoreToolWebsearchExpressions(t *testing.T) {
	f := newStoreToolFixture(t, true)
	contents := []string{"foo bar", "foo distant bar", "foo alone", "bar baz", "bar baz skip", "ordinary", `quoted "value"`}
	for i, content := range contents {
		message := map[string]any{"id": fmt.Sprintf("66666666-6666-4666-8666-%012d", i), "role": "assistant", "content": content, "date": i}
		if err := f.store.Update(storeToolTestConversation, storeToolTestJSON(t, storeToolTestHeader(t, f.store, storeToolTestConversation)), storeToolTestJSON(t, message)); err != nil {
			t.Fatal(err)
		}
	}
	for i, test := range []struct {
		query string
		want  []string
	}{
		{"foo bar", []string{"foo bar", "foo distant bar"}},
		{"foo OR bar", contents[:5]},
		{`"foo bar"`, []string{"foo bar"}},
		{"foo -bar", []string{"foo alone"}},
		{`foo OR "bar baz" -skip`, contents[:4]},
		{`"quoted \"value\""`, []string{`quoted "value"`}},
	} {
		result, err := f.store.ExecuteConversationTool(f.input(t, fmt.Sprint("expression", i), "search_chat_history", map[string]any{"query": test.query}))
		if err != nil {
			t.Fatal(err)
		}
		var decoded struct {
			Results []struct {
				Content string `json:"content"`
			} `json:"results"`
		}
		_ = json.Unmarshal([]byte(result), &decoded)
		var got []string
		for _, hit := range decoded.Results {
			got = append(got, hit.Content)
		}
		if storeToolTestJSON(t, got) != storeToolTestJSON(t, test.want) {
			t.Fatalf("expression %q: got %v want %v", test.query, got, test.want)
		}
	}
	for _, query := range []string{"OR foo", "foo OR", "foo OR OR bar", "- foo", "--foo", `""`, `"a"b`, "(foo)",
		strings.Repeat("x", 1025), strings.Repeat("x ", 33)} {
		if _, err := storeToolParseSearch(query); err == nil {
			t.Fatalf("invalid expression accepted: %q", query)
		}
	}
	for _, test := range []struct {
		raw  string
		want int
	}{{"", 10}, {"null", 10}, {"99999", 30}, {"-10", 1}, {"2.5", 3}, {`"4"`, 4}, {`"bad"`, 10}, {"false", 1}, {`{}`, 10}} {
		if got := storeToolSearchLimit(json.RawMessage(test.raw)); got != test.want {
			t.Fatal("legacy-compatible limit normalization differed", test.raw, got)
		}
	}
}
