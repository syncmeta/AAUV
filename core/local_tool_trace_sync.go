package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
)

func validTraceRevision(value string) bool {
	if len(value) != 19 {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	number, err := strconv.ParseInt(value, 10, 64)
	return err == nil && number > 0
}
func toolTraceFromMessage(payload string) (*localToolTrace, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil || fields == nil {
		return nil, errors.New("invalid message payload")
	}
	raw, ok := fields["localToolTrace"]
	if !ok {
		return nil, nil
	}
	trace, err := decodeLocalToolTrace(raw)
	if err != nil {
		return nil, err
	}
	return &trace, nil
}
func messageTraceClock(payload string) (int64, error) {
	trace, err := toolTraceFromMessage(payload)
	if err != nil {
		return 0, err
	}
	if trace == nil {
		return 0, nil
	}
	return strconv.ParseInt(trace.RunRevision, 10, 64)
}

// Outbox staging is also a low-level opaque storage primitive. Public message
// entry points validate bodies; only an actual trace object adds a clock here.
func stagedMessageTraceClock(payload string) (int64, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil || fields == nil {
		return 0, nil
	}
	raw, ok := fields["localToolTrace"]
	if !ok {
		return 0, nil
	}
	trace, err := decodeLocalToolTrace(raw)
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(trace.RunRevision, 10, 64)
}

func (s *LocalStore) nextToolRunRevision(name, payload string) (string, error) {
	var clock int64
	rows, err := s.run("SELECT revision FROM replica WHERE name=?", name)
	if err != nil {
		return "", err
	}
	if len(rows) > 0 {
		clock, err = strconv.ParseInt(rows[0], 10, 64)
		if err != nil {
			return "", err
		}
	}
	prior, err := messageTraceClock(payload)
	if err != nil {
		return "", err
	}
	clock = max(clock, prior)
	if clock == math.MaxInt64 {
		return "", errors.New("replica_revision_exhausted")
	}
	return fmt.Sprintf("%019d", clock+1), nil
}
func traceStateRank(state string) int {
	switch state {
	case "succeeded":
		return 4
	case "partial":
		return 3
	case "failed":
		return 2
	case "interrupted":
		return 1
	default:
		return 0
	}
}
func joinTraceEntry(a, b localToolTraceEntry) localToolTraceEntry {
	sequence := min(a.Sequence, b.Sequence)
	left, right := a, b
	left.Sequence = sequence
	right.Sequence = sequence
	chooseRight := traceStateRank(right.State) > traceStateRank(left.State)
	if traceStateRank(right.State) == traceStateRank(left.State) {
		x, _ := json.Marshal(left)
		y, _ := json.Marshal(right)
		chooseRight = bytes.Compare(y, x) > 0
	}
	if chooseRight {
		return right
	}
	return left
}
func joinLocalToolTraces(a, b *localToolTrace) (*localToolTrace, error) {
	if a == nil {
		return b, nil
	}
	if b == nil {
		return a, nil
	}
	if a.RunRevision != b.RunRevision {
		if a.RunRevision > b.RunRevision {
			return a, nil
		}
		return b, nil
	}
	if a.RequestID != b.RequestID {
		if a.RequestID > b.RequestID {
			return a, nil
		}
		return b, nil
	}
	result := localToolTrace{Version: 1, RequestID: a.RequestID, RunRevision: a.RunRevision, Entries: []localToolTraceEntry{}}
	entries := map[string]localToolTraceEntry{}
	for _, trace := range []*localToolTrace{a, b} {
		for _, entry := range trace.Entries {
			if old, exists := entries[entry.ID]; exists {
				entries[entry.ID] = joinTraceEntry(old, entry)
			} else {
				entries[entry.ID] = entry
			}
		}
	}
	if len(entries) > localToolTraceCalls {
		return nil, errors.New("tool_breadcrumb_union_limit")
	}
	for _, entry := range entries {
		result.Entries = append(result.Entries, entry)
	}
	sort.Slice(result.Entries, func(i, j int) bool {
		a, b := result.Entries[i], result.Entries[j]
		if a.Sequence != b.Sequence {
			return a.Sequence < b.Sequence
		}
		return a.ID < b.ID
	})
	if _, err := encodeLocalToolTrace(result); err != nil {
		return nil, err
	}
	return &result, nil
}
func sameLocalToolTrace(a, b *localToolTrace) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}
func setMessageToolTrace(payload string, trace *localToolTrace) (string, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil {
		return "", errors.New("invalid message payload")
	}
	if trace == nil {
		delete(fields, "localToolTrace")
	} else {
		raw, err := encodeLocalToolTrace(*trace)
		if err != nil {
			return "", err
		}
		fields["localToolTrace"] = raw
	}
	data, err := json.Marshal(fields)
	if err != nil {
		return "", err
	}
	return canonicalMessageToolTrace(string(data))
}

// mergeReplicaToolTrace leaves the normal body disposition untouched. If the
// body is stale, only the current payload's safe trace can improve. A derived
// outbox revision propagates joined history back to the other peer.
func (s *LocalStore) mergeReplicaToolTrace(record replicaRecord, decision replicaDisposition) (replicaRecord, bool, error) {
	if record.Kind != "message" {
		return record, false, nil
	}
	rows, err := s.run("SELECT "+replicaJSON+" FROM replica WHERE name=?", record.Name)
	if err != nil {
		return record, false, err
	}
	if len(rows) == 0 {
		return record, false, nil
	}
	var prior replicaRecord
	if json.Unmarshal([]byte(rows[0]), &prior) != nil {
		return record, false, errors.New("invalid replica record")
	}
	if prior.Kind != "message" || prior.Conversation != record.Conversation {
		return record, false, nil
	}
	deleted, err := s.run("SELECT name FROM replica WHERE name=? AND kind='deleted'", "c-"+record.Conversation)
	if err != nil || len(deleted) > 0 {
		return record, false, err
	}
	currentTrace, err := toolTraceFromMessage(prior.Payload)
	if err != nil {
		return record, false, err
	}
	incomingTrace, err := toolTraceFromMessage(record.Payload)
	if err != nil {
		return record, false, err
	}
	merged, err := joinLocalToolTraces(currentTrace, incomingTrace)
	if err != nil {
		return record, false, err
	}
	chosen := record
	original := incomingTrace
	if decision == ignoreReplica {
		chosen = prior
		original = currentTrace
	}
	if sameLocalToolTrace(original, merged) {
		return record, false, nil
	}
	chosen.Payload, err = setMessageToolTrace(chosen.Payload, merged)
	if err != nil {
		return record, false, err
	}
	a, err := strconv.ParseInt(prior.Revision, 10, 64)
	if err != nil {
		return record, false, err
	}
	b, err := strconv.ParseInt(record.Revision, 10, 64)
	if err != nil {
		return record, false, err
	}
	clock := max(a, b)
	if clock == math.MaxInt64 {
		return record, false, errors.New("replica_revision_exhausted")
	}
	chosen.Revision = fmt.Sprintf("%019d", clock+1)
	return chosen, true, nil
}

// ConversationMessage is a targeted local snapshot used after Core has reset a
// run. Swift never manufactures runRevision/sequence or reloads an old header.
func (s *LocalStore) ConversationMessage(conversationID, messageID string) (string, error) {
	if !validNodeUUID(conversationID) || !validNodeUUID(messageID) {
		return "", errors.New("invalid_message_identity")
	}
	result := ""
	err := s.transaction(false, func() error {
		c, m, err := s.resolveMessageDeletionIdentity(conversationID, messageID)
		if err != nil {
			return err
		}
		rows, err := s.run("SELECT payload FROM message WHERE id=? AND conversation_id=?", m, c)
		if err != nil {
			return err
		}
		if len(rows) != 1 {
			return errors.New("message_does_not_exist")
		}
		result = rows[0]
		return nil
	})
	return result, err
}

// Only the same outer revision can share current-record file authority.
// A lower revision, even one with an identical body or trace-derived successor,
// cannot prove attachment bytes from names/sizes. It may contribute trace only.
// Within the current revision, semantic body normalization preserves replay
// repair without replacing any body fields or clearing a newer pending record.
func (s *LocalStore) equivalentMessageBody(record replicaRecord) (bool, error) {
	if record.Kind != "message" {
		return false, nil
	}
	rows, err := s.run("SELECT "+replicaJSON+" FROM replica WHERE name=?", record.Name)
	if err != nil || len(rows) == 0 {
		return false, err
	}
	var prior replicaRecord
	if json.Unmarshal([]byte(rows[0]), &prior) != nil {
		return false, errors.New("invalid replica record")
	}
	if prior.Kind != "message" || prior.Conversation != record.Conversation || prior.Revision != record.Revision {
		return false, nil
	}
	deleted, err := s.run("SELECT name FROM replica WHERE name=? AND kind='deleted'", "c-"+record.Conversation)
	if err != nil || len(deleted) > 0 {
		return false, err
	}
	body := func(payload string) ([]byte, error) {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(payload), &fields) != nil || fields == nil {
			return nil, errors.New("invalid message payload")
		}
		delete(fields, "localToolTrace")
		data, err := json.Marshal(fields)
		if err != nil {
			return nil, err
		}
		return storeToolCanonicalJSON(data)
	}
	a, err := body(prior.Payload)
	if err != nil {
		return false, err
	}
	b, err := body(record.Payload)
	if err != nil {
		return false, err
	}
	return bytes.Equal(a, b), nil
}
