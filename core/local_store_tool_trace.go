package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
)

const toolTraceActivePrefix = "conversation_tool_trace_active:"

type toolTraceInput struct {
	ConversationID  string          `json:"conversation_id"`
	UserMessageID   string          `json:"user_message_id"`
	RequestID       string          `json:"request_id"`
	ExpectedBot     json.RawMessage `json:"expected_bot"`
	HistoryRevision *string         `json:"history_revision,omitempty"`
	Event           json.RawMessage `json:"event"`
}
type toolTraceOwner struct {
	ConversationID string `json:"conversation_id"`
	UserMessageID  string `json:"user_message_id"`
	RequestID      string `json:"request_id"`
}
type toolTraceAttempt struct {
	ID            string `json:"id"`
	UserMessageID string `json:"userMessageID"`
	Phase         string `json:"phase"`
}

func toolTraceActiveAttempts(header string) []toolTraceAttempt {
	var value struct {
		Attempts []toolTraceAttempt `json:"replyAttempts"`
	}
	_ = json.Unmarshal([]byte(header), &value)
	result := []toolTraceAttempt{}
	for _, a := range value.Attempts {
		if validNodeUUID(a.ID) && validNodeUUID(a.UserMessageID) && (a.Phase == "preparing" || a.Phase == "submitted") {
			result = append(result, a)
		}
	}
	return result
}
func traceOwnerKey(c, m string) string {
	return toolTraceActivePrefix + strings.ToLower(c) + ":" + strings.ToLower(m)
}
func (s *LocalStore) traceIndex(owner toolTraceOwner, running bool) error {
	key := traceOwnerKey(owner.ConversationID, owner.UserMessageID)
	if !running {
		_, err := s.run("DELETE FROM metadata WHERE key=?", key)
		return err
	}
	data, _ := json.Marshal(owner)
	_, err := s.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, string(data))
	return err
}

// RecordConversationToolBreadcrumb stores safe UI history only. It does not
// execute a tool, accept provider parameters/results or extend authorization.
// The returned value is the atomically updated parent user-message payload.
func (s *LocalStore) RecordConversationToolBreadcrumb(inputJSON string) (string, error) {
	var input toolTraceInput
	if len(inputJSON) > storeToolInputLimit || traceStrictDecode([]byte(inputJSON), &input) != nil || !validNodeUUID(input.ConversationID) || !validNodeUUID(input.UserMessageID) || !validNodeUUID(input.RequestID) || len(input.ExpectedBot) == 0 {
		return "", errors.New("invalid_tool_breadcrumb_input")
	}
	event, err := decodeTraceEvent(input.Event)
	if err != nil {
		return "", err
	}
	result := ""
	err = s.transaction(true, func() error {
		input.ConversationID, input.UserMessageID, err = s.resolveMessageDeletionIdentity(input.ConversationID, input.UserMessageID)
		if err != nil {
			return err
		}
		deleted, err := s.deletedMessage(input.ConversationID, input.UserMessageID)
		if err != nil {
			return err
		}
		if deleted {
			return errors.New("message_was_deleted")
		}
		headers, err := s.run("SELECT header FROM conversation WHERE id=?", input.ConversationID)
		if err != nil {
			return err
		}
		if len(headers) != 1 {
			return errors.New("conversation_tool_conversation_missing")
		}
		// Resolve only the casing of the existing UUID; still require the original
		// single active request and original-bot hash chain below.
		matched := false
		for _, a := range toolTraceActiveAttempts(headers[0]) {
			if strings.EqualFold(a.ID, input.RequestID) && strings.EqualFold(a.UserMessageID, input.UserMessageID) {
				if matched {
					return errors.New("conversation_tool_request_inactive")
				}
				input.RequestID = a.ID
				matched = true
			}
		}
		if !matched {
			return errors.New("conversation_tool_request_inactive")
		}
		revision, err := s.historyRevision(input.ConversationID)
		if err != nil {
			return err
		}
		supplied := ""
		if input.HistoryRevision != nil {
			supplied = *input.HistoryRevision
		}
		if revision != supplied {
			return errors.New("stale_conversation_history")
		}
		scope := storeToolInput{ConversationID: input.ConversationID, UserMessageID: input.UserMessageID, RequestID: input.RequestID, CallID: event.ID, Name: event.Function, Arguments: json.RawMessage("{}"), ExpectedBot: input.ExpectedBot}
		encoded, _ := json.Marshal(scope)
		scope, _, expectedHash, err := storeToolDecodeInput(string(encoded))
		if err != nil {
			return err
		}
		ctx, err := s.storeToolLoadContext(scope, expectedHash)
		if err != nil {
			return err
		}
		rows, err := s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", input.UserMessageID, input.ConversationID)
		if err != nil {
			return err
		}
		if len(rows) != 1 {
			return errors.New("conversation_tool_question_missing")
		}
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(rows[0]), &fields) != nil {
			return errors.New("invalid message payload")
		}
		trace := localToolTrace{Version: 1, RequestID: strings.ToLower(input.RequestID), Entries: []localToolTraceEntry{}}
		if len(fields["localToolTrace"]) == 0 {
			trace.RunRevision, err = s.nextToolRunRevision("m-"+input.UserMessageID, rows[0])
			if err != nil {
				return err
			}
		}
		if raw := fields["localToolTrace"]; len(raw) > 0 {
			trace, err = decodeLocalToolTrace(raw)
			if err != nil {
				return err
			}
			if !strings.EqualFold(trace.RequestID, input.RequestID) {
				return errors.New("tool_breadcrumb_run_changed")
			}
		}
		found := -1
		for i, prior := range trace.Entries {
			if prior.ID == event.ID {
				found = i
				break
			}
		}
		if found < 0 {
			if event.State != "running" || len(trace.Entries) >= localToolTraceCalls {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			event.Sequence = 0
			for _, prior := range trace.Entries {
				if event.Sequence <= prior.Sequence {
					event.Sequence = prior.Sequence + 1
				}
			}
			if event.Sequence >= localToolTraceCalls {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			trace.Entries = append(trace.Entries, event)
		} else {
			previous := trace.Entries[found]
			event.Sequence = previous.Sequence
			if previous.Function != event.Function {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			if event.Query == nil {
				event.Query = previous.Query
				event.QueryTruncated = previous.QueryTruncated
			} else if previous.Query == nil || *event.Query != *previous.Query || !traceBoolEqual(event.QueryTruncated, previous.QueryTruncated) {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			if event.SkillName == nil {
				event.SkillName = previous.SkillName
			} else if previous.SkillName == nil || *event.SkillName != *previous.SkillName {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			a, _ := json.Marshal(previous)
			b, _ := json.Marshal(event)
			if previous.State != "running" && !bytes.Equal(a, b) {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			if previous.State == "running" && event.State == "running" && !bytes.Equal(a, b) {
				return errors.New("invalid_tool_breadcrumb_transition")
			}
			trace.Entries[found] = event
		}
		fields["localToolTrace"], err = encodeLocalToolTrace(trace)
		if err != nil {
			return err
		}
		result, err = s.writeMessageFields(input.ConversationID, input.UserMessageID, fields)
		if err != nil {
			return err
		}
		// Share the existing request's original/current bot chain. A later own
		// create_skill update may advance CurrentBot; callers cannot replace origin.
		state, _ := json.Marshal(ctx.state)
		if _, err = s.run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", storeToolRequestPrefix+input.RequestID, string(state)); err != nil {
			return err
		}
		return s.traceIndex(toolTraceOwner{input.ConversationID, input.UserMessageID, input.RequestID}, traceHasRunning(trace))
	})
	if err != nil {
		return "", err
	}
	return result, nil
}
func traceBoolEqual(a, b *bool) bool { return (a == nil || !*a) == (b == nil || !*b) }

// Only known attempt differences touch message rows. This avoids scanning all
// historical messages on every write and does not infer ownership from UI state.
func (s *LocalStore) reconcileToolTraceHeader(conversationID, oldHeader, newHeader string) error {
	oldRuns := toolTraceActiveAttempts(oldHeader)
	newRuns := toolTraceActiveAttempts(newHeader)
	for _, old := range oldRuns {
		still := false
		for _, next := range newRuns {
			if strings.EqualFold(old.ID, next.ID) && strings.EqualFold(old.UserMessageID, next.UserMessageID) {
				still = true
			}
		}
		if !still {
			if err := s.finishOwnedToolTrace(toolTraceOwner{conversationID, old.UserMessageID, old.ID}, false); err != nil {
				return err
			}
		}
	}
	for _, next := range newRuns {
		existed := false
		for _, old := range oldRuns {
			if strings.EqualFold(old.ID, next.ID) && strings.EqualFold(old.UserMessageID, next.UserMessageID) {
				existed = true
			}
		}
		if !existed {
			if err := s.resetToolTraceForAttempt(toolTraceOwner{conversationID, next.UserMessageID, next.ID}); err != nil {
				return err
			}
		}
	}
	return nil
}
func (s *LocalStore) resetToolTraceForAttempt(owner toolTraceOwner) error {
	rows, err := s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", owner.UserMessageID, owner.ConversationID)
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(rows[0]), &fields) != nil {
		return errors.New("invalid message payload")
	}
	if raw := fields["localToolTrace"]; len(raw) > 0 {
		existing, err := decodeLocalToolTrace(raw)
		if err != nil {
			return err
		}
		if strings.EqualFold(existing.RequestID, owner.RequestID) {
			return nil
		}
	}
	clock, err := s.nextToolRunRevision("m-"+owner.UserMessageID, rows[0])
	if err != nil {
		return err
	}
	trace := localToolTrace{Version: 1, RequestID: strings.ToLower(owner.RequestID), RunRevision: clock, Entries: []localToolTraceEntry{}}
	fields["localToolTrace"], err = encodeLocalToolTrace(trace)
	if err != nil {
		return err
	}
	if _, err = s.writeMessageFields(owner.ConversationID, owner.UserMessageID, fields); err != nil {
		return err
	}
	return s.traceIndex(owner, false)
}
func (s *LocalStore) finishOwnedToolTrace(owner toolTraceOwner, onlyIfInactive bool) error {
	if onlyIfInactive {
		headers, err := s.run("SELECT header FROM conversation WHERE id=?", owner.ConversationID)
		if err != nil {
			return err
		}
		if len(headers) == 1 {
			for _, a := range toolTraceActiveAttempts(headers[0]) {
				if strings.EqualFold(a.ID, owner.RequestID) && strings.EqualFold(a.UserMessageID, owner.UserMessageID) {
					return nil
				}
			}
		}
	}
	rows, err := s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", owner.UserMessageID, owner.ConversationID)
	if err != nil {
		return err
	}
	if len(rows) == 1 {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(rows[0]), &fields) != nil {
			return errors.New("invalid message payload")
		}
		if raw := fields["localToolTrace"]; len(raw) > 0 {
			trace, err := decodeLocalToolTrace(raw)
			if err != nil {
				return err
			}
			if strings.EqualFold(trace.RequestID, owner.RequestID) && interruptTrace(&trace) {
				fields["localToolTrace"], err = encodeLocalToolTrace(trace)
				if err != nil {
					return err
				}
				if _, err = s.writeMessageFields(owner.ConversationID, owner.UserMessageID, fields); err != nil {
					return err
				}
			}
		}
	}
	return s.traceIndex(owner, false)
}
func (s *LocalStore) recoverToolTraceOwners() error {
	return s.transaction(true, func() error {
		rows, err := s.run("SELECT value FROM metadata WHERE key>=? AND key<?", toolTraceActivePrefix, strings.TrimSuffix(toolTraceActivePrefix, ":")+";")
		if err != nil {
			return err
		}
		for _, raw := range rows {
			var owner toolTraceOwner
			if traceStrictDecode([]byte(raw), &owner) != nil || !validNodeUUID(owner.ConversationID) || !validNodeUUID(owner.UserMessageID) || !validNodeUUID(owner.RequestID) {
				return errors.New("invalid_tool_breadcrumb_owner")
			}
			if err = s.finishOwnedToolTrace(owner, true); err != nil {
				return err
			}
		}
		return nil
	})
}
func (s *LocalStore) removeToolTraceOwners(conversationID string) error {
	prefix := toolTraceActivePrefix + strings.ToLower(conversationID) + ":"
	_, err := s.run("DELETE FROM metadata WHERE key>=? AND key<?", prefix, strings.TrimSuffix(prefix, ":")+";")
	return err
}
func (s *LocalStore) prepareLocalMessageTrace(conversationID, payload string) (string, error) {
	payload, err := canonicalMessageToolTrace(payload)
	if err != nil {
		return "", err
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal([]byte(payload), &fields)
	var messageID, role string
	_ = json.Unmarshal(fields["id"], &messageID)
	_ = json.Unmarshal(fields["role"], &role)
	if role != "user" {
		return payload, nil
	}
	headers, err := s.run("SELECT header FROM conversation WHERE id=?", conversationID)
	if err != nil {
		return "", err
	}
	var active *toolTraceAttempt
	if len(headers) == 1 {
		for _, a := range toolTraceActiveAttempts(headers[0]) {
			if strings.EqualFold(a.UserMessageID, messageID) {
				if active != nil {
					return "", errors.New("conversation_tool_request_inactive")
				}
				copy := a
				active = &copy
			}
		}
	}
	var trace *localToolTrace
	if raw := fields["localToolTrace"]; len(raw) > 0 {
		decoded, err := decodeLocalToolTrace(raw)
		if err != nil {
			return "", err
		}
		trace = &decoded
	}
	if active != nil && (trace == nil || !strings.EqualFold(trace.RequestID, active.ID)) {
		clock, err := s.nextToolRunRevision("m-"+messageID, payload)
		if err != nil {
			return "", err
		}
		trace = &localToolTrace{Version: 1, RequestID: strings.ToLower(active.ID), RunRevision: clock, Entries: []localToolTraceEntry{}}
	}
	if trace == nil {
		return payload, nil
	}
	live := active != nil && strings.EqualFold(trace.RequestID, active.ID)
	if !live {
		interruptTrace(trace)
	}
	owner := toolTraceOwner{conversationID, messageID, trace.RequestID}
	if live {
		owner.RequestID = active.ID
	}
	fields["localToolTrace"], err = encodeLocalToolTrace(*trace)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(fields)
	if err != nil {
		return "", err
	}
	if err = s.traceIndex(owner, live && traceHasRunning(*trace)); err != nil {
		return "", err
	}
	return string(data), nil
}
