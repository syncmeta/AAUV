package aauvcore

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
)

const messageDeletedKind = "message_deleted"

// DeleteMessage removes exactly one local message. A durable tombstone prevents
// older replicas or local imports from reusing its identity. Other messages,
// including explicit replies to the deleted prompt, retain their identities.
func (s *LocalStore) DeleteMessage(conversationID, messageID string) error {
	if !validNodeUUID(conversationID) || !validNodeUUID(messageID) {
		return errors.New("invalid_message_deletion")
	}
	return s.transaction(true, func() error {
		// Foundation renders UUID.uuidString in uppercase; Go/remote imports
		// may retain lowercase. Resolve this new API's identity without
		// rewriting existing rows or guessing between ambiguous identities.
		var err error
		conversationID, messageID, err = s.resolveMessageDeletionIdentity(conversationID, messageID)
		if err != nil {
			return err
		}
		rows, err := s.run("SELECT json_array(conversation,kind) FROM replica WHERE name=?", "m-"+messageID)
		if err != nil {
			return err
		}
		if len(rows) > 0 {
			var prior []string
			if json.Unmarshal([]byte(rows[0]), &prior) != nil || len(prior) != 2 {
				return errors.New("invalid_message_record")
			}
			if prior[0] != conversationID {
				return errors.New("message_conversation_mismatch")
			}
			if prior[1] == messageDeletedKind {
				return nil
			}
		}
		rows, err = s.run("SELECT conversation_id FROM message WHERE id=?", messageID)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			return errors.New("message_does_not_exist")
		}
		if rows[0] != conversationID {
			return errors.New("message_conversation_mismatch")
		}
		if err = s.removeMessageForDeletion(conversationID, messageID); err != nil {
			return err
		}
		return s.stageRecord("m-"+messageID, messageDeletedKind, conversationID, "")
	})
}

func (s *LocalStore) resolveMessageDeletionIdentity(conversationID, messageID string) (string, string, error) {
	chats, err := s.run("SELECT id FROM conversation WHERE lower(id)=lower(?)", conversationID)
	if err != nil {
		return "", "", err
	}
	if len(chats) > 1 {
		return "", "", errors.New("message_identity_ambiguous")
	}
	rows, err := s.run(`SELECT json_array(id,conversation_id) FROM message WHERE lower(id)=lower(?)
        UNION SELECT json_array(substr(name,3),conversation) FROM replica
        WHERE kind IN ('message','message_deleted') AND lower(name)=lower(?)`, messageID, "m-"+messageID)
	if err != nil {
		return "", "", err
	}
	if len(rows) == 0 {
		return "", "", errors.New("message_does_not_exist")
	}
	if len(rows) != 1 {
		return "", "", errors.New("message_identity_ambiguous")
	}
	var identity []string
	if json.Unmarshal([]byte(rows[0]), &identity) != nil || len(identity) != 2 {
		return "", "", errors.New("invalid_message_record")
	}
	if !strings.EqualFold(identity[1], conversationID) {
		return "", "", errors.New("message_conversation_mismatch")
	}
	return identity[1], identity[0], nil
}

// historyRevision is derived from durable tombstone identities. It fences only
// deletion-induced history changes, not ordinary reply/credential updates. It
// is returned by Snapshot and never trusted from imported or synced headers.
func (s *LocalStore) historyRevision(conversationID string) (string, error) {
	names, err := s.run("SELECT name FROM replica WHERE conversation=? AND kind=? ORDER BY name", conversationID, messageDeletedKind)
	if err != nil || len(names) == 0 {
		return "", err
	}
	data, err := json.Marshal(names)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

func (s *LocalStore) prepareHistoryHeader(conversationID, header string, checkRevision bool) (string, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(header), &fields) != nil || fields == nil {
		return "", errors.New("invalid conversation header")
	}
	if checkRevision {
		expected, err := s.historyRevision(conversationID)
		if err != nil {
			return "", err
		}
		var supplied string
		if raw := fields["historyRevision"]; len(raw) > 0 && json.Unmarshal(raw, &supplied) != nil {
			return "", errors.New("stale_conversation_history")
		}
		if supplied != expected {
			return "", errors.New("stale_conversation_history")
		}
	}
	delete(fields, "historyRevision")
	delete(fields, "messages") // Normalized message rows are the sole owner.
	if _, exists := fields["localToolTrace"]; exists {
		return "", errors.New("invalid_local_tool_trace")
	}
	if _, err := s.stripDeletedReferences(conversationID, fields); err != nil {
		return "", err
	}
	data, err := json.Marshal(fields)
	return string(data), err
}

func (s *LocalStore) deletedMessage(conversationID, messageID string) (bool, error) {
	if messageID == "" {
		return false, nil
	}
	rows, err := s.run("SELECT conversation FROM replica WHERE name=? AND kind=?", "m-"+messageID, messageDeletedKind)
	if err != nil || len(rows) == 0 {
		return false, err
	}
	if rows[0] != conversationID {
		return false, errors.New("message_conversation_mismatch")
	}
	return true, nil
}

func (s *LocalStore) sanitizeMessageReferences(conversationID, payload string) (string, error) {
	var err error
	payload, err = canonicalMessageToolTrace(payload)
	if err != nil {
		return "", err
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil || fields == nil {
		return "", errors.New("invalid message payload")
	}
	var selected string
	if json.Unmarshal(fields["selectedReplyID"], &selected) == nil && selected != "" {
		deleted, err := s.deletedMessage(conversationID, selected)
		if err != nil {
			return "", err
		}
		if deleted {
			delete(fields, "selectedReplyID")
			data, err := json.Marshal(fields)
			return string(data), err
		}
	}
	return payload, nil
}

// Only known tombstones invalidate references. A reply or selection whose
// target has not arrived yet remains valid for out-of-order synchronization.
func (s *LocalStore) stripDeletedReferences(conversationID string, fields map[string]json.RawMessage) (bool, error) {
	changed := false
	var selections map[string]string
	if json.Unmarshal(fields["selectedReplies"], &selections) == nil {
		for parent, reply := range selections {
			a, err := s.deletedMessage(conversationID, parent)
			if err != nil {
				return false, err
			}
			b, err := s.deletedMessage(conversationID, reply)
			if err != nil {
				return false, err
			}
			if a || b {
				delete(selections, parent)
				changed = true
			}
		}
		if changed {
			if len(selections) == 0 {
				delete(fields, "selectedReplies")
			} else {
				fields["selectedReplies"], _ = json.Marshal(selections)
			}
		}
	}
	var attempts []json.RawMessage
	if json.Unmarshal(fields["replyAttempts"], &attempts) == nil {
		keep := make([]json.RawMessage, 0, len(attempts))
		removed := false
		for _, raw := range attempts {
			var attempt struct {
				UserMessageID string `json:"userMessageID"`
			}
			_ = json.Unmarshal(raw, &attempt)
			deleted, err := s.deletedMessage(conversationID, attempt.UserMessageID)
			if err != nil {
				return false, err
			}
			if deleted {
				removed = true
				continue
			}
			keep = append(keep, raw)
		}
		if removed {
			changed = true
			delete(fields, "compression")
			if len(keep) == 0 {
				delete(fields, "replyAttempts")
			} else {
				fields["replyAttempts"], _ = json.Marshal(keep)
			}
		}
	}
	return changed, nil
}

func (s *LocalStore) removeMessageForDeletion(conversationID, messageID string) error {
	if _, err := s.run("DELETE FROM message WHERE id=? AND conversation_id=?", messageID, conversationID); err != nil {
		return err
	}
	// The new tombstone may not have been staged yet. Remove references to this
	// exact identity explicitly, while the common sanitizer covers older ones.
	messages, err := s.run(`SELECT payload FROM replica WHERE conversation=? AND kind='message' AND name<>?
        UNION ALL SELECT m.payload FROM message m WHERE m.conversation_id=? AND m.id<>?
        AND NOT EXISTS (SELECT 1 FROM replica r WHERE r.name='m-'||m.id AND r.kind='message')`,
		conversationID, "m-"+messageID, conversationID, messageID)
	if err != nil {
		return err
	}
	for _, payload := range messages {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(payload), &fields) != nil {
			return errors.New("invalid message payload")
		}
		var selected, id string
		_ = json.Unmarshal(fields["selectedReplyID"], &selected)
		_ = json.Unmarshal(fields["id"], &id)
		if selected == messageID {
			delete(fields, "selectedReplyID")
			if _, err = s.writeMessageFields(conversationID, id, fields); err != nil {
				return err
			}
		}
	}
	headers, err := s.run("SELECT header FROM conversation WHERE id=?", conversationID)
	if err != nil || len(headers) == 0 {
		return err
	}
	var header map[string]json.RawMessage
	if json.Unmarshal([]byte(headers[0]), &header) != nil {
		return errors.New("invalid conversation header")
	}
	delete(header, "compression")
	delete(header, "replyAttempts")
	delete(header, "historyRevision")
	var choices map[string]string
	if json.Unmarshal(header["selectedReplies"], &choices) == nil {
		for prompt, reply := range choices {
			if prompt == messageID || reply == messageID {
				delete(choices, prompt)
			}
		}
		if len(choices) == 0 {
			delete(header, "selectedReplies")
		} else {
			header["selectedReplies"], _ = json.Marshal(choices)
		}
	}
	data, err := json.Marshal(header)
	if err != nil {
		return err
	}
	if err = s.reconcileToolTraceHeader(conversationID, headers[0], string(data)); err != nil {
		return err
	}
	if _, err = s.run("UPDATE conversation SET header=? WHERE id=?", string(data), conversationID); err != nil {
		return err
	}
	return s.stageConversation(conversationID, string(data))
}

// Recover normalized rows that an older writer left beside a tombstone. Normal
// opens with no stale rows preserve newer requests and compression state.
func (s *LocalStore) repairDeletedMessageRows() error {
	return s.transaction(true, s.repairDeletedMessageRowsLocked)
}
func (s *LocalStore) repairDeletedMessageRowsLocked() error {
	rows, err := s.run("SELECT json_array(m.conversation_id,m.id,r.conversation) FROM message m JOIN replica r ON r.name='m-'||m.id WHERE r.kind=?", messageDeletedKind)
	if err != nil {
		return err
	}
	for _, raw := range rows {
		var item []string
		if json.Unmarshal([]byte(raw), &item) != nil || len(item) != 3 {
			return errors.New("invalid_message_record")
		}
		if item[0] != item[2] {
			return errors.New("message_conversation_mismatch")
		}
		if err = s.removeMessageForDeletion(item[0], item[1]); err != nil {
			return err
		}
	}
	return nil
}

// AttachmentReferences returns one consistent snapshot of physical file names.
// Parent-less message replicas also retain their files until their chat arrives.
// Callers must only collect deletion candidates and leave files untouched on error.
func (s *LocalStore) AttachmentReferences() (string, error) {
	names := make(zipFiles)
	err := s.transaction(false, func() error {
		rows, err := s.run("SELECT header FROM conversation UNION ALL SELECT payload FROM message UNION ALL SELECT payload FROM replica WHERE kind IN ('conversation','message')")
		if err != nil {
			return err
		}
		for _, raw := range rows {
			var value struct {
				Attachments []backupAttachment `json:"attachments"`
			}
			if json.Unmarshal([]byte(raw), &value) != nil {
				return errors.New("invalid_attachment_references")
			}
			if err = names.add(value.Attachments); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	result := make([]string, 0, len(names))
	for name := range names {
		result = append(result, name)
	}
	sort.Strings(result)
	data, err := json.Marshal(result)
	return string(data), err
}

// The payload lookup and application share normalization, so an exact replay
// can still repair missing attachment files after a deleted choice is stripped.
func (s *LocalStore) sanitizeReplicaReferences(record *replicaRecord) error {
	if record.Kind == "message" {
		payload, err := s.sanitizeMessageReferences(record.Conversation, record.Payload)
		if err != nil {
			return err
		}
		record.Payload = payload
		clock, err := messageTraceClock(payload)
		if err != nil {
			return err
		}
		outer, err := strconv.ParseInt(record.Revision, 10, 64)
		if err != nil || clock > outer {
			return errors.New("invalid_tool_run_revision")
		}
	}
	if record.Kind == "conversation" {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(record.Payload), &fields) != nil || fields == nil {
			return errors.New("invalid replica header")
		}
		_, hadRevision := fields["historyRevision"]
		_, hadMessages := fields["messages"]
		if _, exists := fields["localToolTrace"]; exists {
			return errors.New("invalid_local_tool_trace")
		}
		delete(fields, "messages")
		delete(fields, "historyRevision")
		changed, err := s.stripDeletedReferences(record.Conversation, fields)
		if err != nil {
			return err
		}
		if changed || hadRevision || hadMessages {
			data, err := json.Marshal(fields)
			if err != nil {
				return err
			}
			record.Payload = string(data)
		}
	}
	return nil
}
