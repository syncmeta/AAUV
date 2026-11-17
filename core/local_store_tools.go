package aauvcore

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const storeToolReceiptPrefix = "conversation_tool_receipt:"
const storeToolRequestPrefix = "conversation_tool_request:"
const storeToolInputLimit = 2 * 1024 * 1024

type storeToolInput struct {
	ConversationID string          `json:"conversation_id"`
	UserMessageID  string          `json:"user_message_id"`
	RequestID      string          `json:"request_id"`
	CallID         string          `json:"call_id"`
	Name           string          `json:"name"`
	Arguments      json.RawMessage `json:"arguments"`
	ExpectedBot    json.RawMessage `json:"expected_bot"`
}

type storeToolRequestState struct {
	ConversationID string `json:"conversation_id"`
	UserMessageID  string `json:"user_message_id"`
	ExpectedBot    string `json:"expected_bot_hash"`
	CurrentBot     string `json:"current_bot_hash"`
}

type storeToolReceipt struct {
	Fingerprint string          `json:"fingerprint"`
	Result      json.RawMessage `json:"result"`
}

type storeToolContext struct {
	header map[string]json.RawMessage
	bot    json.RawMessage
	hash   string
	state  storeToolRequestState
}

// ExecuteConversationTool executes only the two local conversation tools. The
// caller supplies the original bot snapshot for this ReplyAttempt and migrates
// legacy instructions before calling. Context failures return an error; ordinary
// tool/argument failures return model-readable {"error":...} JSON.
//
// Receipts and the request's bot-hash chain are local metadata, not replica data.
// They commit atomically with a created skill, chat instructions and both outbox
// records. A replay is permitted only while the same request is still active.
func (s *LocalStore) ExecuteConversationTool(inputJSON string) (string, error) {
	input, fingerprint, expectedHash, err := storeToolDecodeInput(inputJSON)
	if err != nil {
		return "", err
	}
	result := ""
	err = s.transaction(true, func() error {
		ctx, err := s.storeToolLoadContext(input, expectedHash)
		if err != nil {
			return err
		}
		key := storeToolReceiptPrefix + input.RequestID + ":" + input.CallID
		prior, err := s.run("SELECT value FROM metadata WHERE key=?", key)
		if err != nil {
			return err
		}
		if len(prior) != 0 {
			var receipt storeToolReceipt
			if json.Unmarshal([]byte(prior[0]), &receipt) != nil || !json.Valid(receipt.Result) {
				return errors.New("conversation_tool_invalid_receipt")
			}
			if receipt.Fingerprint != fingerprint {
				return errors.New("conversation_tool_call_conflict")
			}
			result = string(receipt.Result)
			return nil
		}
		switch input.Name {
		case "search_chat_history":
			result, err = s.storeToolSearchHistory(input)
		case "create_skill":
			result, err = s.storeToolCreateSkill(input, &ctx)
		default:
			result = storeToolErrorResult("unsupported_tool")
		}
		if err != nil {
			return err
		}
		ctx.state.CurrentBot = ctx.hash
		state, err := json.Marshal(ctx.state)
		if err != nil {
			return err
		}
		if _, err = s.run(`INSERT INTO metadata(key,value) VALUES (?,?)
ON CONFLICT(key) DO UPDATE SET value=excluded.value`, storeToolRequestPrefix+input.RequestID, string(state)); err != nil {
			return err
		}
		receipt, err := json.Marshal(storeToolReceipt{Fingerprint: fingerprint, Result: json.RawMessage(result)})
		if err != nil {
			return err
		}
		_, err = s.run("INSERT INTO metadata(key,value) VALUES (?,?)", key, string(receipt))
		return err
	})
	if err != nil {
		return "", err
	}
	return result, nil
}

func storeToolDecodeInput(text string) (storeToolInput, string, string, error) {
	var input storeToolInput
	invalid := errors.New("conversation_tool_invalid_input")
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.DisallowUnknownFields()
	if len(text) > storeToolInputLimit || !utf8.ValidString(text) || !json.Valid([]byte(text)) || decoder.Decode(&input) != nil ||
		!validNodeUUID(input.ConversationID) || !validNodeUUID(input.UserMessageID) || !validNodeUUID(input.RequestID) ||
		input.CallID == "" || len(input.CallID) > 256 || strings.IndexFunc(input.CallID, unicode.IsControl) >= 0 ||
		input.Name == "" || len(input.Name) > 128 {
		return input, "", "", invalid
	}
	var arguments map[string]json.RawMessage
	if json.Unmarshal(input.Arguments, &arguments) != nil || arguments == nil || len(input.ExpectedBot) == 0 {
		return input, "", "", invalid
	}
	var bot map[string]json.RawMessage
	if !bytes.Equal(bytes.TrimSpace(input.ExpectedBot), []byte("null")) &&
		(json.Unmarshal(input.ExpectedBot, &bot) != nil || bot == nil) {
		return input, "", "", invalid
	}
	if bot != nil {
		var identity struct {
			Name        string `json:"name"`
			Endpoint    string `json:"endpoint"`
			Model       string `json:"model"`
			LoginMethod string `json:"loginMethod"`
		}
		if json.Unmarshal(input.ExpectedBot, &identity) != nil || strings.TrimSpace(identity.Name) == "" ||
			strings.TrimSpace(identity.Endpoint) == "" || (identity.LoginMethod != "copilot" && strings.TrimSpace(identity.Model) == "") ||
			(identity.LoginMethod != "byok" && identity.LoginMethod != "chatgpt" && identity.LoginMethod != "copilot") {
			return input, "", "", invalid
		}
	}
	var err error
	input.Arguments, err = storeToolCanonicalJSON(input.Arguments)
	if err != nil {
		return input, "", "", invalid
	}
	input.ExpectedBot, err = storeToolCanonicalBot(input.ExpectedBot)
	if err != nil {
		return input, "", "", invalid
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		return input, "", "", invalid
	}
	return input, storeToolHash(encoded), storeToolHash(input.ExpectedBot), nil
}

func storeToolCanonicalJSON(raw json.RawMessage) (json.RawMessage, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	return json.Marshal(value)
}

// Swift's optional BotSnapshot fields decode null and an absent key identically.
// Normalize only those known optional nils for matching; retain the original bot
// JSON separately so creating a skill does not erase unrelated stored fields.
func storeToolCanonicalBot(raw json.RawMessage) (json.RawMessage, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	if fields == nil {
		return json.RawMessage("null"), nil
	}
	for _, key := range []string{"apiProtocol", "hostedTools", "chatGPTClientID", "profileID", "instructions"} {
		if bytes.Equal(bytes.TrimSpace(fields[key]), []byte("null")) {
			delete(fields, key)
		}
	}
	normalizeUUID := func(object map[string]json.RawMessage, key string) {
		var id string
		if json.Unmarshal(object[key], &id) == nil && validNodeUUID(id) {
			object[key], _ = json.Marshal(strings.ToLower(id))
		}
	}
	normalizeUUID(fields, "profileID")
	if instructions := fields["instructions"]; len(instructions) != 0 {
		var document map[string]json.RawMessage
		if json.Unmarshal(instructions, &document) != nil || document == nil {
			return nil, errors.New("invalid bot instructions")
		}
		if bytes.Equal(bytes.TrimSpace(document["skillEntries"]), []byte("null")) {
			delete(document, "skillEntries")
		}
		if rawEntries := document["skillEntries"]; len(rawEntries) != 0 {
			var entries []map[string]json.RawMessage
			if json.Unmarshal(rawEntries, &entries) != nil {
				return nil, errors.New("invalid bot skills")
			}
			for _, entry := range entries {
				normalizeUUID(entry, "id")
			}
			document["skillEntries"], _ = json.Marshal(entries)
		}
		fields["instructions"], _ = json.Marshal(document)
	}
	encoded, err := json.Marshal(fields)
	if err != nil {
		return nil, err
	}
	return storeToolCanonicalJSON(encoded)
}

func storeToolHash(value []byte) string {
	hash := sha256.Sum256(value)
	return hex.EncodeToString(hash[:])
}

func storeToolErrorResult(message string) string {
	encoded, _ := json.Marshal(map[string]string{"error": message})
	return string(encoded)
}

func (s *LocalStore) storeToolLoadContext(input storeToolInput, expectedHash string) (storeToolContext, error) {
	ctx := storeToolContext{}
	rows, err := s.run("SELECT header FROM conversation WHERE id=?", input.ConversationID)
	if err != nil {
		return ctx, err
	}
	if len(rows) != 1 || json.Unmarshal([]byte(rows[0]), &ctx.header) != nil {
		return ctx, errors.New("conversation_tool_conversation_missing")
	}
	var headerID string
	if json.Unmarshal(ctx.header["id"], &headerID) != nil || headerID != input.ConversationID {
		return ctx, errors.New("conversation_tool_invalid_conversation")
	}
	var attempts []struct {
		ID            string `json:"id"`
		UserMessageID string `json:"userMessageID"`
		Phase         string `json:"phase"`
	}
	if json.Unmarshal(ctx.header["replyAttempts"], &attempts) != nil {
		return ctx, errors.New("conversation_tool_request_inactive")
	}
	active, matched := 0, false
	for _, attempt := range attempts {
		if attempt.Phase == "preparing" || attempt.Phase == "submitted" {
			active++
			if attempt.ID == input.RequestID && attempt.UserMessageID == input.UserMessageID {
				matched = true
			}
		}
	}
	if !matched || active != 1 {
		return ctx, errors.New("conversation_tool_request_inactive")
	}
	rows, err = s.run(`SELECT payload FROM message WHERE id=? AND conversation_id=?
AND json_extract(payload,'$.role')='user' AND coalesce(json_extract(payload,'$.status'),'')<>'deleted'`, input.UserMessageID, input.ConversationID)
	if err != nil {
		return ctx, err
	}
	if len(rows) != 1 {
		return ctx, errors.New("conversation_tool_question_missing")
	}
	ctx.bot = ctx.header["bot"]
	if len(ctx.bot) == 0 {
		ctx.bot = json.RawMessage("null")
	}
	ctx.bot, err = storeToolCanonicalJSON(ctx.bot)
	if err != nil {
		return ctx, errors.New("conversation_tool_invalid_bot")
	}
	matchedBot, err := storeToolCanonicalBot(ctx.bot)
	if err != nil {
		return ctx, errors.New("conversation_tool_invalid_bot")
	}
	ctx.hash = storeToolHash(matchedBot)
	ctx.state = storeToolRequestState{ConversationID: input.ConversationID, UserMessageID: input.UserMessageID,
		ExpectedBot: expectedHash, CurrentBot: expectedHash}
	rows, err = s.run("SELECT value FROM metadata WHERE key=?", storeToolRequestPrefix+input.RequestID)
	if err != nil {
		return ctx, err
	}
	if len(rows) != 0 && json.Unmarshal([]byte(rows[0]), &ctx.state) != nil {
		return ctx, errors.New("conversation_tool_invalid_request_state")
	}
	if ctx.state.ConversationID != input.ConversationID || ctx.state.UserMessageID != input.UserMessageID ||
		ctx.state.ExpectedBot != expectedHash || ctx.state.CurrentBot != ctx.hash {
		return ctx, errors.New("conversation_tool_bot_changed")
	}
	return ctx, nil
}

func (s *LocalStore) storeToolSearchHistory(input storeToolInput) (string, error) {
	var args map[string]json.RawMessage
	_ = json.Unmarshal(input.Arguments, &args)
	stringArgument := func(key string) string {
		var value string
		_ = json.Unmarshal(args[key], &value)
		return strings.TrimSpace(value)
	}
	query, since, until := stringArgument("query"), stringArgument("since"), stringArgument("until")
	if query == "" && since == "" && until == "" {
		return storeToolErrorResult("at least one of query / since / until is required"), nil
	}
	where := `conversation_id=? AND json_extract(payload,'$.role') IN ('user','assistant')
AND coalesce(json_extract(payload,'$.status'),'')<>'deleted' AND json_type(payload,'$.content')='text'`
	binds := []string{input.ConversationID}
	for _, item := range []struct{ key, value string }{{"since", since}, {"until", until}} {
		if item.value == "" {
			continue
		}
		parsed, err := time.Parse(time.RFC3339Nano, item.value)
		if err != nil {
			parsed, err = time.Parse("2006-01-02", item.value)
		}
		if err != nil {
			return storeToolErrorResult(item.key + " is not a valid ISO date"), nil
		}
		op := ">="
		if item.key == "until" {
			op = "<"
		}
		where += " AND json_type(payload,'$.date') IN ('integer','real') AND json_extract(payload,'$.date') " + op + " CAST(? AS REAL)"
		binds = append(binds, strconv.FormatFloat(float64(parsed.Unix())+float64(parsed.Nanosecond())/1e9-978307200, 'g', -1, 64))
	}
	if query != "" {
		groups, err := storeToolParseSearch(query)
		if err != nil {
			return storeToolErrorResult("invalid query syntax: " + err.Error()), nil
		}
		predicate, words := storeToolSearchSQL(groups)
		where += " AND " + predicate
		binds = append(binds, words...)
	}
	limit := storeToolSearchLimit(args["limit"])
	binds = append(binds, strconv.Itoa(limit))
	rows, err := s.run(`SELECT json_object('role',json_extract(payload,'$.role'),
'date',CASE WHEN json_type(payload,'$.date') IN ('integer','real') THEN json_extract(payload,'$.date') ELSE NULL END,
'content',substr(json_extract(payload,'$.content'),1,400)) FROM message WHERE `+where+`
ORDER BY CASE WHEN json_type(payload,'$.date') IN ('integer','real') THEN json_extract(payload,'$.date') ELSE NULL END DESC,
ordering DESC LIMIT CAST(? AS INTEGER)`, binds...)
	if err != nil {
		return "", err
	}
	type hit struct {
		When    *string `json:"when"`
		Speaker string  `json:"speaker"`
		Content string  `json:"content"`
	}
	results := make([]hit, 0, len(rows))
	for i := len(rows) - 1; i >= 0; i-- {
		var row struct {
			Role    string   `json:"role"`
			Date    *float64 `json:"date"`
			Content string   `json:"content"`
		}
		if json.Unmarshal([]byte(rows[i]), &row) != nil {
			return "", errors.New("conversation_tool_invalid_message")
		}
		item := hit{Speaker: "them", Content: row.Content}
		if row.Role == "assistant" {
			item.Speaker = "me"
		}
		if row.Date != nil && *row.Date+978307200 >= -62135596800 && *row.Date+978307200 < 253402300800 {
			seconds, fractional := math.Modf(*row.Date + 978307200)
			value := time.Unix(int64(seconds), int64(fractional*1e9)).UTC().Format(time.RFC3339Nano)
			item.When = &value
		}
		results = append(results, item)
	}
	hint := "没有命中。换个关键词或放宽时间范围。"
	if len(results) != 0 {
		hint = "结果按时间从早到晚；speaker=me 是助手，them 是用户。when=null 表示原记录没有可用时间；结果之间可能有其他消息。"
	}
	encoded, err := json.Marshal(struct {
		Results []hit  `json:"results"`
		Hint    string `json:"hint"`
	}{results, hint})
	return string(encoded), err
}

func storeToolSearchLimit(raw json.RawMessage) int {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&value) != nil || value == nil {
		return 10
	}
	var number float64
	var err error
	switch typed := value.(type) {
	case json.Number:
		number, err = typed.Float64()
	case string:
		if strings.TrimSpace(typed) != "" {
			number, err = strconv.ParseFloat(strings.TrimSpace(typed), 64)
		}
	case bool:
		if typed {
			number = 1
		}
	default:
		return 10
	}
	if err != nil || math.IsInf(number, 0) || math.IsNaN(number) {
		return 10
	}
	return int(math.Max(1, math.Min(30, math.Round(number))))
}

var storeToolSkillNamePattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

func (s *LocalStore) storeToolCreateSkill(input storeToolInput, ctx *storeToolContext) (string, error) {
	var args struct {
		Name        string `json:"name"`
		Description string `json:"description"`
		Body        string `json:"body"`
	}
	if json.Unmarshal(input.Arguments, &args) != nil {
		return storeToolErrorResult("name, description and body must be strings"), nil
	}
	args.Name, args.Description = strings.TrimSpace(args.Name), strings.TrimSpace(args.Description)
	if args.Name == "" {
		return storeToolErrorResult("name is required"), nil
	}
	if utf8.RuneCountInString(args.Name) > 80 || !storeToolSkillNamePattern.MatchString(args.Name) {
		return storeToolErrorResult("name must be lowercase kebab-case, at most 80 characters"), nil
	}
	if utf8.RuneCountInString(args.Description) > 2000 {
		return storeToolErrorResult("description exceeds 2000 characters"), nil
	}
	if strings.TrimSpace(args.Body) == "" || utf8.RuneCountInString(args.Body) > 65536 {
		return storeToolErrorResult("body must be nonempty and at most 65536 characters"), nil
	}
	var bot map[string]json.RawMessage
	if json.Unmarshal(ctx.bot, &bot) != nil || bot == nil {
		return storeToolErrorResult("needs_bound_bot"), nil
	}
	emptyPrompt, emptySkills := "", ""
	global := botInstructions{Prompt: &emptyPrompt, Skills: &emptySkills}
	rows, err := s.run("SELECT payload FROM replica WHERE name=? AND kind='instructions'", instructionsRecord)
	if err != nil {
		return "", err
	}
	if len(rows) != 0 {
		var stored botInstructions
		if validateInstructions(rows[0]) != nil || json.Unmarshal([]byte(rows[0]), &stored) != nil {
			return "", errors.New("conversation_tool_invalid_library")
		}
		global = stored
	}
	// AAUV composes global + bot instructions. A bot without its own document
	// starts empty here, otherwise copying global would duplicate it next turn.
	local := botInstructions{Prompt: &emptyPrompt, Skills: &emptySkills}
	if raw := bot["instructions"]; len(raw) != 0 && string(raw) != "null" {
		var provided botInstructions
		if validateInstructions(string(raw)) != nil || json.Unmarshal(raw, &provided) != nil {
			return "", errors.New("conversation_tool_invalid_bot_instructions")
		}
		local = provided
	}
	var uuid [16]byte
	if _, err = rand.Read(uuid[:]); err != nil {
		return "", errors.New("conversation_tool_id_generation_failed")
	}
	uuid[6], uuid[8] = uuid[6]&0x0f|0x40, uuid[8]&0x3f|0x80
	id := fmt.Sprintf("%x-%x-%x-%x-%x", uuid[0:4], uuid[4:6], uuid[6:8], uuid[8:10], uuid[10:16])
	markdown := args.Body
	if args.Description != "" {
		markdown = args.Description + "\n\n" + args.Body
	}
	no, yes := false, true
	skill := botSkill{ID: id, Name: args.Name, Markdown: markdown, Enabled: &no}
	global.SkillEntries = append(global.SkillEntries, skill)
	skill.Enabled = &yes
	local.SkillEntries = append(local.SkillEntries, skill)
	if global.validate() != nil || local.validate() != nil {
		return storeToolErrorResult("skill library or conversation instructions exceed their 100-skill / 512-KB limit"), nil
	}
	globalJSON, err := json.Marshal(global)
	if err != nil {
		return "", err
	}
	bot["instructions"], err = json.Marshal(local)
	if err != nil {
		return "", err
	}
	botJSON, err := json.Marshal(bot)
	if err != nil {
		return "", err
	}
	ctx.bot, err = storeToolCanonicalJSON(botJSON)
	if err != nil {
		return "", err
	}
	ctx.header["bot"] = ctx.bot
	headerJSON, err := json.Marshal(ctx.header)
	if err != nil {
		return "", err
	}
	if err = s.stageRecord(instructionsRecord, "instructions", "", string(globalJSON)); err != nil {
		return "", err
	}
	if _, err = s.run("UPDATE conversation SET header=? WHERE id=?", string(headerJSON), input.ConversationID); err != nil {
		return "", err
	}
	if err = s.stageConversation(input.ConversationID, string(headerJSON)); err != nil {
		return "", err
	}
	matchedBot, err := storeToolCanonicalBot(ctx.bot)
	if err != nil {
		return "", err
	}
	ctx.hash = storeToolHash(matchedBot)
	encoded, err := json.Marshal(struct {
		SkillID    string `json:"skill_id"`
		Name       string `json:"name"`
		Subscribed bool   `json:"subscribed"`
	}{id, args.Name, true})
	return string(encoded), err
}
