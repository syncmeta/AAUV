package aauvcore

import (
	"encoding/json"
	"strings"
)

// pruneConversationToolState runs under the store's write transaction. Receipts
// are an idempotency journal for active attempts, not retained chat history.
// Durable preparing/submitted attempts are kept even when another window/process
// owns them; no in-memory activity state or wall-clock expiry is consulted.
func (s *LocalStore) pruneConversationToolState() error {
	// The fixed ':'-terminated prefixes have ';' as their exclusive upper
	// bound, so SQLite can use the metadata primary-key index on every write.
	rows, err := s.run(`SELECT json_array(key,value) FROM metadata
WHERE key>=? AND key<?`, storeToolRequestPrefix, strings.TrimSuffix(storeToolRequestPrefix, ":")+";")
	if err != nil {
		return err
	}
	active := make(map[string]bool, len(rows))
	for _, row := range rows {
		var fields []string
		if err := json.Unmarshal([]byte(row), &fields); err != nil {
			return err
		}
		requestID := strings.TrimPrefix(fields[0], storeToolRequestPrefix)
		var state storeToolRequestState
		keep := false
		if validNodeUUID(requestID) && json.Unmarshal([]byte(fields[1]), &state) == nil &&
			validNodeUUID(state.ConversationID) && validNodeUUID(state.UserMessageID) {
			keep, err = s.storeToolRequestActive(requestID, state)
			if err != nil {
				return err
			}
		}
		if keep {
			active[requestID] = true
		} else if _, err := s.run("DELETE FROM metadata WHERE key=?", fields[0]); err != nil {
			return err
		}
	}
	// Also remove orphan receipts from interrupted older cleanup attempts, even
	// when their request-state row is already missing or malformed.
	receipts, err := s.run(`SELECT key FROM metadata
WHERE key>=? AND key<?`, storeToolReceiptPrefix, strings.TrimSuffix(storeToolReceiptPrefix, ":")+";")
	if err != nil {
		return err
	}
	for _, key := range receipts {
		requestID, callID, separated := strings.Cut(strings.TrimPrefix(key, storeToolReceiptPrefix), ":")
		if separated && callID != "" && active[requestID] {
			continue
		}
		if _, err := s.run("DELETE FROM metadata WHERE key=?", key); err != nil {
			return err
		}
	}
	return nil
}

func (s *LocalStore) storeToolRequestActive(requestID string, state storeToolRequestState) (bool, error) {
	rows, err := s.run("SELECT header FROM conversation WHERE id=?", state.ConversationID)
	if err != nil || len(rows) != 1 {
		return false, err
	}
	var header struct {
		ID       string `json:"id"`
		Attempts []struct {
			ID            string `json:"id"`
			UserMessageID string `json:"userMessageID"`
			Phase         string `json:"phase"`
		} `json:"replyAttempts"`
	}
	if json.Unmarshal([]byte(rows[0]), &header) != nil || header.ID != state.ConversationID {
		return false, nil
	}
	matched := false
	for _, attempt := range header.Attempts {
		if attempt.ID == requestID && attempt.UserMessageID == state.UserMessageID &&
			(attempt.Phase == "preparing" || attempt.Phase == "submitted") {
			matched = true
			break
		}
	}
	if !matched {
		return false, nil
	}
	rows, err = s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", state.UserMessageID, state.ConversationID)
	if err != nil || len(rows) != 1 {
		return false, err
	}
	var message struct {
		Role   string `json:"role"`
		Status string `json:"status"`
	}
	return json.Unmarshal([]byte(rows[0]), &message) == nil && message.Role == "user" && message.Status != "deleted", nil
}
