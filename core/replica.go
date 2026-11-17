package aauvcore

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

type replicaRecord struct {
	Name         string `json:"name"`
	Kind         string `json:"kind"`
	Conversation string `json:"conversation"`
	Revision     string `json:"revision"`
	Payload      string `json:"payload"`
}

const instructionsRecord = "p-instructions"
const replicaMessageRepair = "replica_message_payload_v2"

const replicaSchema = `
CREATE TABLE IF NOT EXISTS replica (
 name TEXT PRIMARY KEY, kind TEXT NOT NULL, conversation TEXT NOT NULL,
 revision TEXT NOT NULL, payload TEXT NOT NULL, pending INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS replica_parent ON replica(conversation,kind);
CREATE INDEX IF NOT EXISTS replica_pending_order ON replica(revision,name) WHERE pending=1;
`

const replicaJSON = `json_object('name',name,'kind',kind,'conversation',conversation,'revision',revision,'payload',payload)`

// Older builds could accept a replica revision without updating the displayed
// message. Reconcile the two tables once, without changing message identities.
func (s *LocalStore) repairReplicaMessagePayloads() error {
	return s.transaction(true, func() error {
		state, err := s.run("SELECT value FROM metadata WHERE key=?", replicaMessageRepair)
		if err != nil || len(state) != 0 {
			return err
		}
		if _, err := s.run(`UPDATE message SET payload=replica.payload
			FROM replica WHERE replica.name='m-' || message.id AND replica.kind='message'
				AND replica.conversation=message.conversation_id AND replica.payload<>message.payload`); err != nil {
			return err
		}
		_, err = s.run("INSERT INTO metadata(key,value) VALUES (?, '1')", replicaMessageRepair)
		return err
	})
}

func (s *LocalStore) stageRecord(name, kind, conversation, payload string) error {
	return s.stageRecordAt(name, kind, conversation, payload, time.Now().UnixNano())
}

func (s *LocalStore) stageRecordAt(name, kind, conversation, payload string, now int64) error {
	if kind == "message" {
		clock, err := stagedMessageTraceClock(payload)
		if err != nil {
			return err
		}
		now = max(now, clock)
	}
	existing, err := s.run("SELECT json_array(revision,payload,kind) FROM replica WHERE name=?", name)
	if err != nil {
		return err
	}
	if len(existing) > 0 {
		var prior []string
		if err := json.Unmarshal([]byte(existing[0]), &prior); err != nil {
			return err
		}
		if prior[2] == messageDeletedKind && kind == "message" {
			return errors.New("message_was_deleted")
		}
		if prior[1] == payload && prior[2] == kind {
			return nil
		}
		old, err := strconv.ParseInt(prior[0], 10, 64)
		if err != nil {
			return err
		}
		if old == math.MaxInt64 {
			return errors.New("replica_revision_exhausted")
		}
		now = max(now, old+1)
	}
	_, err = s.run(`INSERT INTO replica(name,kind,conversation,revision,payload,pending)
 VALUES(?,?,?,?,?,1) ON CONFLICT(name) DO UPDATE SET kind=excluded.kind,
 revision=excluded.revision,payload=excluded.payload,pending=1`,
		name, kind, conversation, fmt.Sprintf("%019d", now), payload)
	return err
}

func (s *LocalStore) stageConversation(id, header string) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(header), &fields); err != nil {
		return err
	}
	delete(fields, "replyAttempts")
	delete(fields, "compression")
	delete(fields, "messages")
	delete(fields, "historyRevision")
	data, err := json.Marshal(fields)
	if err != nil {
		return err
	}
	return s.stageRecord("c-"+id, "conversation", id, string(data))
}

// PrepareReplica seeds the outbox once, including data stored by older builds.
func (s *LocalStore) PrepareReplica() error {
	return s.transaction(true, func() error {
		if err := s.repairDeletedMessageRowsLocked(); err != nil {
			return err
		}
		state, err := s.run("SELECT value FROM metadata WHERE key='replica_seeded'")
		if err != nil || len(state) > 0 {
			return err
		}
		headers, err := s.run("SELECT header FROM conversation")
		if err != nil {
			return err
		}
		for _, header := range headers {
			var value struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal([]byte(header), &value); err != nil {
				return err
			}
			if err := s.stageConversation(value.ID, header); err != nil {
				return err
			}
			messages, err := s.run("SELECT payload FROM message WHERE conversation_id=?", value.ID)
			if err != nil {
				return err
			}
			for _, message := range messages {
				var item struct {
					ID string `json:"id"`
				}
				if err := json.Unmarshal([]byte(message), &item); err != nil {
					return err
				}
				if err := s.stageRecord("m-"+item.ID, "message", value.ID, message); err != nil {
					return err
				}
			}
		}
		_, err = s.run("INSERT INTO metadata(key,value) VALUES ('replica_seeded','1')")
		return err
	})
}

func (s *LocalStore) PendingReplica() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run(`SELECT ` + replicaJSON + ` FROM replica WHERE pending=1 ORDER BY revision,name`)
	if err != nil {
		return "", err
	}
	data := make([]json.RawMessage, 0, len(rows))
	for _, row := range rows {
		data = append(data, json.RawMessage(row))
	}
	payload, err := json.Marshal(data)
	return string(payload), err
}

// PendingReplicaPage lists ordered record references without decoding or
// returning their potentially large message bodies.
func (s *LocalStore) PendingReplicaPage(afterRevision, afterName string, limit int) (string, error) {
	if limit < 1 || limit > 512 {
		return "", errors.New("invalid replica page size")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run(`SELECT json_object('name',name,'revision',revision) FROM replica
		WHERE pending=1 AND (revision,name)>(?,?) ORDER BY revision,name LIMIT ?`,
		afterRevision, afterName, strconv.Itoa(limit))
	if err != nil {
		return "", err
	}
	return "[" + strings.Join(rows, ",") + "]", nil
}

// PendingReplicaRecord loads the exact revision selected from a page. A newer
// local edit or acknowledgement invalidates that selection.
func (s *LocalStore) PendingReplicaRecord(name, revision string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run(`SELECT `+replicaJSON+` FROM replica WHERE pending=1 AND name=? AND revision=?`, name, revision)
	if err != nil || len(rows) == 0 {
		return "", err
	}
	return rows[0], nil
}

func (s *LocalStore) PendingReplicaRevision(name string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT revision FROM replica WHERE name=? AND pending=1", name)
	if err != nil || len(rows) == 0 {
		return "", err
	}
	return rows[0], nil
}

func (s *LocalStore) PendingReplicaCount() (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT count(*) FROM replica WHERE pending=1")
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(rows[0])
}

func (s *LocalStore) AcknowledgeReplica(name, revision string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.run("UPDATE replica SET pending=0 WHERE name=? AND revision=?", name, revision)
	return err
}

// RequeueReplica republishes the complete local replica after explicit zone recovery.
func (s *LocalStore) RequeueReplica() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.run("UPDATE replica SET pending=1")
	return err
}

// RequeueReplicaRecord repairs a physically removed cloud record, if a local copy exists.
func (s *LocalStore) RequeueReplicaRecord(name string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.run("UPDATE replica SET pending=1 WHERE name=?", name)
	return err
}

// Instructions returns the synchronized local document, or an empty string
// when this installation has not stored one yet.
func (s *LocalStore) Instructions() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT payload FROM replica WHERE name=? AND kind='instructions'", instructionsRecord)
	if err != nil || len(rows) == 0 {
		return "", err
	}
	return rows[0], nil
}

func (s *LocalStore) SetInstructions(payload string) error {
	if err := validateInstructions(payload); err != nil {
		return err
	}
	return s.transaction(true, func() error {
		return s.stageRecord(instructionsRecord, "instructions", "", payload)
	})
}

// SeedInstructions imports an older file without overriding a replica already
// applied on this installation. Preserve its modification time for conflict ordering.
func (s *LocalStore) SeedInstructions(payload string, modified int64) error {
	if err := validateInstructions(payload); err != nil {
		return err
	}
	if modified <= 0 {
		return errors.New("invalid instructions modification time")
	}
	return s.transaction(true, func() error {
		rows, err := s.run("SELECT name FROM replica WHERE name=?", instructionsRecord)
		if err != nil || len(rows) > 0 {
			return err
		}
		return s.stageRecordAt(instructionsRecord, "instructions", "", payload, min(modified, time.Now().UnixNano()))
	})
}

func validateInstructions(payload string) error {
	var document botInstructions
	decoder := json.NewDecoder(strings.NewReader(payload))
	decoder.DisallowUnknownFields()
	if !json.Valid([]byte(payload)) || decoder.Decode(&document) != nil {
		return errors.New("invalid instructions document")
	}
	return document.validate()
}

func parseReplica(payload string) (replicaRecord, error) {
	var record replicaRecord
	if err := json.Unmarshal([]byte(payload), &record); err != nil {
		return record, err
	}
	revision, err := strconv.ParseInt(record.Revision, 10, 64)
	if err != nil || revision <= 0 || len(record.Revision) != 19 {
		return record, errors.New("invalid replica revision")
	}
	if record.Conversation == "" {
		switch record.Kind {
		case "instructions", "bot", "bot_deleted", "profile", "model_services":
		default:
			return record, errors.New("invalid replica parent")
		}
	}
	if record.Kind == messageDeletedKind {
		if record.Payload != "" || !validNodeUUID(record.Conversation) || !strings.HasPrefix(record.Name, "m-") || !validNodeUUID(strings.TrimPrefix(record.Name, "m-")) {
			return record, errors.New("invalid message tombstone")
		}
	}
	if record.Kind == "message" {
		var message struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal([]byte(record.Payload), &message); err != nil || message.ID == "" || record.Name != "m-"+message.ID {
			return record, errors.New("invalid replica message")
		}
	}
	if record.Kind == "profile" || record.Kind == "model_services" {
		if err := validatePublicPreferenceRecord(record); err != nil {
			return record, err
		}
	}
	return record, nil
}

type replicaDisposition int

const (
	ignoreReplica replicaDisposition = iota
	acknowledgeReplica
	mergeReplica
)

func (s *LocalStore) disposition(record replicaRecord) (replicaDisposition, error) {
	if record.Kind == "message" || record.Kind == messageDeletedKind {
		tombstone, err := s.run("SELECT name FROM replica WHERE name=? AND kind='deleted'", "c-"+record.Conversation)
		if err != nil || len(tombstone) > 0 {
			return ignoreReplica, err
		}
		parent, err := s.run("SELECT conversation_id FROM message WHERE id=?", record.Name[2:])
		if err != nil {
			return ignoreReplica, err
		}
		if len(parent) > 0 && parent[0] != record.Conversation {
			return ignoreReplica, errors.New("replica message conversation mismatch")
		}
	}
	prior, err := s.run("SELECT json_array(kind,revision,payload,conversation,CAST(pending AS TEXT)) FROM replica WHERE name=?", record.Name)
	if err != nil {
		return ignoreReplica, err
	}
	if len(prior) > 0 {
		var row []string
		if err := json.Unmarshal([]byte(prior[0]), &row); err != nil {
			return ignoreReplica, err
		}
		if (record.Kind == "message" || record.Kind == messageDeletedKind) && row[3] != record.Conversation {
			return ignoreReplica, errors.New("replica message conversation mismatch")
		}
		if row[0] == record.Kind && row[1] == record.Revision && row[2] == record.Payload {
			return acknowledgeReplica, nil
		}
		if isReplicaDeletion(row[0]) && !isReplicaDeletion(record.Kind) {
			return ignoreReplica, nil
		}
		// Fresh defaults have no user edit timestamp. During the initial fetch,
		// prefer the existing cloud value to this device's unpublished seed.
		if (record.Kind == "profile" || record.Kind == "model_services") && row[0] == record.Kind &&
			record.Revision == "0000000000000000001" && row[1] == record.Revision && row[4] == "1" {
			return mergeReplica, nil
		}
		if (!isReplicaDeletion(record.Kind) || isReplicaDeletion(row[0])) &&
			(row[1] > record.Revision || (row[1] == record.Revision && row[2] >= record.Payload)) {
			return ignoreReplica, nil
		}
	}
	return mergeReplica, nil
}

// NeedsReplicaPayload allows platform adapters to skip stale files. An exact
// replay still supplies its payload so the adapter can repair a missing file.
func (s *LocalStore) NeedsReplicaPayload(payload string) (bool, error) {
	record, err := parseReplica(payload)
	if err != nil {
		return false, err
	}
	needed := false
	err = s.transaction(false, func() error {
		if err := s.sanitizeReplicaReferences(&record); err != nil {
			return err
		}
		decision, err := s.disposition(record)
		needed = decision != ignoreReplica
		if err == nil && !needed {
			needed, err = s.equivalentMessageBody(record)
		}
		return err
	})
	return needed, err
}

// ApplyReplica merges the latest revisions of headers and messages. A conversation
// tombstone wins over every header for that identity, including offline edits.
func (s *LocalStore) ApplyReplica(payload string) error {
	_, err := s.ApplyReplicaChecked(payload)
	return err
}

// ApplyReplicaChecked reports whether the payload was accepted or already present.
func (s *LocalStore) ApplyReplicaChecked(payload string) (bool, error) {
	record, err := parseReplica(payload)
	if err != nil {
		return false, err
	}
	accepted := false
	err = s.transaction(true, func() error {
		if err := s.sanitizeReplicaReferences(&record); err != nil {
			return err
		}
		decision, err := s.disposition(record)
		if err != nil {
			return err
		}
		joined, traceChanged, err := s.mergeReplicaToolTrace(record, decision)
		if err != nil {
			return err
		}
		if decision == ignoreReplica {
			if !traceChanged {
				// ACK only a byte-equivalent normalized body for file repair;
				// leave the newer record revision and pending flag untouched.
				accepted, err = s.equivalentMessageBody(record)
				return err
			}
			if err := s.materializeReplicaMessage(joined); err != nil {
				return err
			}
			clock, _ := strconv.ParseInt(joined.Revision, 10, 64)
			if err := s.stageRecordAt(joined.Name, joined.Kind, joined.Conversation, joined.Payload, clock); err != nil {
				return err
			}
			accepted = true
			return nil
		}
		if traceChanged {
			record = joined
		}

		if decision == acknowledgeReplica {
			if record.Kind == "message" {
				if err := s.materializeReplicaMessage(record); err != nil {
					return err
				}
			}
			accepted = true
			_, err := s.run("UPDATE replica SET pending=0 WHERE name=?", record.Name)
			return err
		}
		switch record.Kind {
		case "profile", "model_services":
			if err := validatePublicPreferenceRecord(record); err != nil {
				return err
			}
		case "instructions":
			if record.Name != instructionsRecord || record.Conversation != "" {
				return errors.New("invalid instructions record")
			}
			if err := validateInstructions(record.Payload); err != nil {
				return err
			}
		case "bot":
			profile, err := validateBotProfile(record.Payload)
			if err != nil || record.Conversation != "" || record.Name != "b-"+profile.ID {
				return errors.New("invalid bot replica")
			}
		case "bot_deleted":
			if record.Conversation != "" || record.Payload != "" ||
				!strings.HasPrefix(record.Name, "b-") || !validNodeUUID(strings.TrimPrefix(record.Name, "b-")) {
				return errors.New("invalid bot tombstone")
			}
		case "conversation":
			var fields map[string]json.RawMessage
			if err := json.Unmarshal([]byte(record.Payload), &fields); err != nil {
				return err
			}
			var id string
			if err := json.Unmarshal(fields["id"], &id); err != nil || id != record.Conversation || record.Name != "c-"+id {
				return errors.New("invalid replica header")
			}
			delete(fields, "messages")
			delete(fields, "replyAttempts")
			delete(fields, "compression")
			delete(fields, "historyRevision")
			if _, err := s.stripDeletedReferences(id, fields); err != nil {
				return err
			}
			existing, err := s.run("SELECT header FROM conversation WHERE id=?", id)
			if err != nil {
				return err
			}
			if len(existing) > 0 {
				var local map[string]json.RawMessage
				if err := json.Unmarshal([]byte(existing[0]), &local); err != nil {
					return err
				}
				for _, key := range []string{"replyAttempts", "compression"} {
					if local[key] != nil {
						fields[key] = local[key]
					}
				}
			}
			header, err := json.Marshal(fields)
			if err != nil {
				return err
			}
			if _, err = s.run(`INSERT INTO conversation(id,header) VALUES (?,?)
    ON CONFLICT(id) DO UPDATE SET header=excluded.header`, id, string(header)); err != nil {
				return err
			}
			if _, err = s.run(`INSERT INTO message(id,conversation_id,payload)
    SELECT substr(name,3),conversation,payload FROM replica WHERE conversation=? AND kind='message' ORDER BY revision,name
    ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
    WHERE message.conversation_id=excluded.conversation_id AND message.payload<>excluded.payload`, id); err != nil {
				return err
			}
		case messageDeletedKind:
			alreadyDeleted, err := s.deletedMessage(record.Conversation, record.Name[2:])
			if err != nil {
				return err
			}
			if !alreadyDeleted {
				if err := s.removeMessageForDeletion(record.Conversation, record.Name[2:]); err != nil {
					return err
				}
			}
		case "message":
			if err := s.materializeReplicaMessage(record); err != nil {
				return err
			}
		case "deleted":
			if err := s.removeToolTraceOwners(record.Conversation); err != nil {
				return err
			}
			if record.Name != "c-"+record.Conversation {
				return errors.New("invalid replica tombstone")
			}
			if _, err = s.run("DELETE FROM conversation WHERE id=?", record.Conversation); err != nil {
				return err
			}
			if _, err = s.run("DELETE FROM replica WHERE conversation=? AND kind='message'", record.Conversation); err != nil {
				return err
			}
		default:
			return errors.New("invalid replica kind")
		}
		pending := "0"
		if traceChanged {
			pending = "1"
		}
		_, err = s.run(`INSERT INTO replica(name,kind,conversation,revision,payload,pending)
   VALUES(?,?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET kind=excluded.kind,
   revision=excluded.revision,payload=excluded.payload,pending=excluded.pending`, record.Name, record.Kind, record.Conversation, record.Revision, record.Payload, pending)
		accepted = err == nil
		return err
	})
	return accepted && err == nil, err
}

func (s *LocalStore) materializeReplicaMessage(record replicaRecord) error {
	_, err := s.run(`INSERT INTO message(id,conversation_id,payload)
    SELECT ?,id,? FROM conversation WHERE id=?
    ON CONFLICT(id) DO UPDATE SET payload=excluded.payload
    WHERE message.conversation_id=excluded.conversation_id AND message.payload<>excluded.payload`,
		record.Name[2:], record.Payload, record.Conversation)
	return err
}

func isReplicaDeletion(kind string) bool {
	return kind == "deleted" || kind == "bot_deleted" || kind == messageDeletedKind
}
