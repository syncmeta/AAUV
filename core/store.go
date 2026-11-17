package aauvcore

/*
#cgo !android,!aauv_bundled_sqlite LDFLAGS: -lsqlite3
#cgo android aauv_bundled_sqlite CFLAGS: -I${SRCDIR}/build/android-sqlite-3540100 -DSQLITE_OMIT_LOAD_EXTENSION -fvisibility=hidden
#cgo android aauv_bundled_sqlite LDFLAGS: -lm
#include <stdlib.h>
#include <sqlite3.h>

static int bind_text(sqlite3_stmt *stmt, int index, const char *text, int size) {
    return sqlite3_bind_text(stmt, index, text, size, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"sync"
	"unsafe"
)

// LocalStore owns the SQLite connection. The mobile adapter supplies an app-private path.
type LocalStore struct {
	mu sync.Mutex
	db *C.sqlite3
}

func OpenLocalStore(path string) (*LocalStore, error) {
	name := C.CString(path)
	defer C.free(unsafe.Pointer(name))
	var db *C.sqlite3
	code := C.sqlite3_open_v2(name, &db, C.SQLITE_OPEN_READWRITE|C.SQLITE_OPEN_CREATE|C.SQLITE_OPEN_FULLMUTEX, nil)
	if code != C.SQLITE_OK {
		if db != nil {
			C.sqlite3_close(db)
		}
		return nil, fmt.Errorf("sqlite open: %d", int(code))
	}
	s := &LocalStore{db: db}
	C.sqlite3_busy_timeout(db, 5000)
	if err := s.exec(`
 PRAGMA foreign_keys=ON;
 CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS conversation (
   ordering INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, header TEXT NOT NULL
 );
 CREATE TABLE IF NOT EXISTS message (
   ordering INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
   conversation_id TEXT NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
   payload TEXT NOT NULL
 );
 CREATE INDEX IF NOT EXISTS message_conversation ON message(conversation_id, ordering);
 ` + replicaSchema + usageSchema); err != nil {
		s.Close()
		return nil, err
	}
	// Startup repairs use write transactions, which also reclaim tool receipts
	// left by older builds while preserving every durable active request.
	if err := s.repairDeletedMessageRows(); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.repairReplicaMessagePayloads(); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.migrateReplyChoices(); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.recoverToolTraceOwners(); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *LocalStore) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		C.sqlite3_close(s.db)
		s.db = nil
	}
}

func (s *LocalStore) exec(sql string) error {
	if s.db == nil {
		return errors.New("sqlite connection closed")
	}
	query := C.CString(sql)
	defer C.free(unsafe.Pointer(query))
	if code := C.sqlite3_exec(s.db, query, nil, nil, nil); code != C.SQLITE_OK {
		return fmt.Errorf("sqlite execute: %d", int(code))
	}
	return nil
}

func (s *LocalStore) run(sql string, args ...string) ([]string, error) {
	if s.db == nil {
		return nil, errors.New("sqlite connection closed")
	}
	query := C.CString(sql)
	defer C.free(unsafe.Pointer(query))
	var stmt *C.sqlite3_stmt
	if code := C.sqlite3_prepare_v2(s.db, query, -1, &stmt, nil); code != C.SQLITE_OK {
		return nil, fmt.Errorf("sqlite prepare: %d", int(code))
	}
	defer C.sqlite3_finalize(stmt)
	for i, arg := range args {
		value := C.CString(arg)
		code := C.bind_text(stmt, C.int(i+1), value, C.int(len(arg)))
		C.free(unsafe.Pointer(value))
		if code != C.SQLITE_OK {
			return nil, fmt.Errorf("sqlite bind: %d", int(code))
		}
	}
	var rows []string
	for {
		switch code := C.sqlite3_step(stmt); code {
		case C.SQLITE_DONE:
			return rows, nil
		case C.SQLITE_ROW:
			rows = append(rows, C.GoStringN((*C.char)(unsafe.Pointer(C.sqlite3_column_text(stmt, 0))), C.sqlite3_column_bytes(stmt, 0)))
		default:
			return nil, fmt.Errorf("sqlite step: %d", int(code))
		}
	}
}

func (s *LocalStore) transaction(write bool, action func() error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	begin := "BEGIN"
	if write {
		begin = "BEGIN IMMEDIATE"
	}
	if err := s.exec(begin); err != nil {
		return err
	}
	defer s.exec("ROLLBACK")
	if err := action(); err != nil {
		return err
	}
	if write {
		// Run after all mutations, inside the same transaction. This includes
		// imports, reply completion, local deletion and replica materialization.
		if err := s.pruneConversationToolState(); err != nil {
			return err
		}
	}
	return s.exec("COMMIT")
}

type storedConversation struct {
	id       string
	header   string
	messages []json.RawMessage
}

func decodeConversation(raw json.RawMessage) (storedConversation, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return storedConversation{}, err
	}
	var entry storedConversation
	if err := json.Unmarshal(fields["id"], &entry.id); err != nil || entry.id == "" {
		return entry, errors.New("invalid conversation ID")
	}
	if err := json.Unmarshal(fields["messages"], &entry.messages); err != nil {
		return entry, err
	}
	delete(fields, "messages")
	header, err := json.Marshal(fields)
	entry.header = string(header)
	return entry, err
}

func (s *LocalStore) appendMessage(id, payload string) error {
	var msg struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(payload), &msg); err != nil || msg.ID == "" {
		return errors.New("invalid message ID")
	}
	deleted, err := s.deletedMessage(id, msg.ID)
	if err != nil {
		return err
	}
	if deleted {
		return errors.New("message_was_deleted")
	}
	var parent struct {
		ReplyTo string `json:"replyTo"`
	}
	_ = json.Unmarshal([]byte(payload), &parent)
	deleted, err = s.deletedMessage(id, parent.ReplyTo)
	if err != nil {
		return err
	}
	if deleted {
		return errors.New("message_parent_was_deleted")
	}
	payload, err = s.sanitizeMessageReferences(id, payload)
	if err != nil {
		return err
	}
	payload, err = s.prepareLocalMessageTrace(id, payload)
	if err != nil {
		return err
	}
	if _, err := s.run("INSERT INTO message(id,conversation_id,payload) VALUES (?,?,?)", msg.ID, id, payload); err != nil {
		return err
	}
	return s.stageRecord("m-"+msg.ID, "message", id, payload)
}

// Insert imports a batch of conversations atomically. A legacy import is recorded
// in the same transaction and can safely be attempted again after a crash.
func (s *LocalStore) Insert(payload string, legacy bool) error {
	return s.transaction(true, func() error {
		if legacy {
			rows, err := s.run("SELECT value FROM metadata WHERE key='legacy_imported'")
			if err != nil || len(rows) > 0 {
				return err
			}
		}
		if err := s.insertConversations(payload); err != nil {
			return err
		}
		if legacy {
			_, err := s.run("INSERT INTO metadata(key,value) VALUES ('legacy_imported','1')")
			return err
		}
		return nil
	})
}

// RestoreCopies commits conversations and bot copies in one SQLite transaction.
func (s *LocalStore) RestoreCopies(conversations, bots string) error {
	return s.RestoreCopiesWithInstructions(conversations, bots, "")
}

// RestoreCopiesWithInstructions also restores the optional shared instructions document.
func (s *LocalStore) RestoreCopiesWithInstructions(conversations, bots, instructions string) error {
	_, err := s.restoreCopies(conversations, bots, instructions, "", "")
	return err
}

// ApplyConfigurationImport records the commit of non-secret configuration data.
// The Apple adapter uses this marker to finish the separate Keychain write.
func (s *LocalStore) ApplyConfigurationImport(id, bots, instructions string) error {
	return s.RestoreCopiesForConfigurationImport(id, "[]", bots, instructions)
}

// RestoreCopiesForConfigurationImport ties a backup restore to the same
// durable marker used to finish configuration publication on the device.
func (s *LocalStore) RestoreCopiesForConfigurationImport(id, conversations, bots, instructions string) error {
	if !validNodeUUID(id) {
		return errors.New("invalid_configuration_import_id")
	}
	_, err := s.restoreCopies(conversations, bots, instructions, id, "")
	return err
}

// RestoreSharedImport records that this inbox item has been committed on this
// device. Replaying it after a crash does not create more copies.
func (s *LocalStore) RestoreSharedImport(sharedID, importID, conversations, bots, instructions string) (bool, error) {
	if !validNodeUUID(sharedID) || (importID != "" && !validNodeUUID(importID)) {
		return false, errors.New("invalid_shared_import_id")
	}
	return s.restoreCopies(conversations, bots, instructions, importID, sharedID)
}

func (s *LocalStore) SharedImportCommitted(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sharedImportCommitted(id)
}

func (s *LocalStore) sharedImportCommitted(id string) (bool, error) {
	rows, err := s.run("SELECT value FROM metadata WHERE key=?", "shared_import:"+id)
	return len(rows) > 0, err
}

func (s *LocalStore) ConfigurationImportCommitted(id string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT value FROM metadata WHERE key='configuration_import' AND value=?", id)
	return len(rows) > 0, err
}

func (s *LocalStore) restoreCopies(conversations, bots, instructions, importID, sharedID string) (bool, error) {
	if instructions != "" {
		if err := validateInstructions(instructions); err != nil {
			return false, err
		}
	}
	applied := false
	err := s.transaction(true, func() error {
		if sharedID != "" {
			committed, err := s.sharedImportCommitted(sharedID)
			if err != nil || committed {
				return err
			}
		}
		if err := s.insertConversations(conversations); err != nil {
			return err
		}
		if err := s.saveBots(bots); err != nil {
			return err
		}
		if instructions != "" {
			if err := s.stageRecord(instructionsRecord, "instructions", "", instructions); err != nil {
				return err
			}
		}
		if importID != "" {
			if _, err := s.run(`INSERT INTO metadata(key,value) VALUES ('configuration_import',?)
			 ON CONFLICT(key) DO UPDATE SET value=excluded.value`, importID); err != nil {
				return err
			}
		}
		if sharedID != "" {
			if _, err := s.run("INSERT INTO metadata(key,value) VALUES (?, '1')", "shared_import:"+sharedID); err != nil {
				return err
			}
		}
		applied = true
		return nil
	})
	return applied && err == nil, err
}

func (s *LocalStore) insertConversations(payload string) error {
	var conversations []json.RawMessage
	if err := json.Unmarshal([]byte(payload), &conversations); err != nil {
		return err
	}
	for i := len(conversations) - 1; i >= 0; i-- {
		entry, err := decodeConversation(conversations[i])
		if err != nil {
			return err
		}
		entry.header, err = s.prepareHistoryHeader(entry.id, entry.header, false)
		if err != nil {
			return err
		}
		if _, err = s.run("INSERT INTO conversation(id,header) VALUES (?,?)", entry.id, entry.header); err != nil {
			return err
		}
		if err = s.stageConversation(entry.id, entry.header); err != nil {
			return err
		}
		for _, msg := range entry.messages {
			if err = s.appendMessage(entry.id, string(msg)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *LocalStore) LegacyImported() (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT value FROM metadata WHERE key='legacy_imported'")
	return len(rows) > 0, err
}

func (s *LocalStore) Snapshot() (string, error) {
	var conversations []json.RawMessage
	err := s.transaction(false, func() error {
		rows, err := s.run("SELECT header FROM conversation ORDER BY ordering DESC")
		if err != nil {
			return err
		}
		conversations = make([]json.RawMessage, 0, len(rows))
		for _, row := range rows {
			var header map[string]json.RawMessage
			if err := json.Unmarshal([]byte(row), &header); err != nil {
				return err
			}
			var id string
			if err := json.Unmarshal(header["id"], &id); err != nil {
				return err
			}
			rows, err := s.run("SELECT payload FROM message WHERE conversation_id=? ORDER BY json_extract(payload,'$.date'),ordering", id)
			if err != nil {
				return err
			}
			messages := make([]json.RawMessage, 0, len(rows))
			for _, message := range rows {
				messages = append(messages, json.RawMessage(message))
			}
			revision, err := s.historyRevision(id)
			if err != nil {
				return err
			}
			delete(header, "historyRevision")
			if revision != "" {
				header["historyRevision"], _ = json.Marshal(revision)
			}
			header["messages"], err = json.Marshal(messages)
			if err != nil {
				return err
			}
			combined, err := json.Marshal(header)
			if err != nil {
				return err
			}
			conversations = append(conversations, combined)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(conversations)
	return string(data), err
}

// Update saves metadata and optionally appends a message as one transaction.
func (s *LocalStore) Update(id, header, message string) error {
	return s.transaction(true, func() error {
		var identity struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal([]byte(header), &identity); err != nil || identity.ID != id {
			return errors.New("invalid conversation header")
		}
		priorHeaders, err := s.run("SELECT header FROM conversation WHERE id=?", id)
		if err != nil {
			return err
		}
		if len(priorHeaders) != 1 {
			return errors.New("conversation does not exist")
		}
		prepared, err := s.prepareHistoryHeader(id, header, true)
		if err != nil {
			return err
		}
		header = prepared
		if _, err := s.run("UPDATE conversation SET header=? WHERE id=?", header, id); err != nil {
			return err
		}
		if C.sqlite3_changes(s.db) != 1 {
			return errors.New("conversation does not exist")
		}
		if err := s.stageConversation(id, header); err != nil {
			return err
		}
		if err := s.reconcileToolTraceHeader(id, priorHeaders[0], header); err != nil {
			return err
		}
		if message != "" {
			return s.appendMessage(id, message)
		}
		return nil
	})
}

// SetReplyChoice updates the prompt and its replica revision together. Choices
// on separate prompts do not compete with each other or with the chat header.
func (s *LocalStore) SetReplyChoice(conversationID, promptID, replyID string) (string, error) {
	payload := ""
	err := s.transaction(true, func() error {
		rows, err := s.run(`SELECT payload FROM message
			WHERE conversation_id=? AND id=? AND json_extract(payload,'$.role')='user'`, conversationID, promptID)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			return errors.New("prompt does not exist")
		}
		payload = rows[0]
		parent, err := s.replyParent(conversationID, replyID)
		if err != nil {
			return err
		}
		if parent != promptID {
			return errors.New("reply does not belong to the prompt")
		}
		payload, err = s.writeReplyChoice(conversationID, promptID, replyID, payload)
		return err
	})
	return payload, err
}

func (s *LocalStore) writeReplyChoice(conversationID, promptID, replyID, payload string) (string, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(payload), &fields); err != nil {
		return "", err
	}
	choice, err := json.Marshal(replyID)
	if err != nil {
		return "", err
	}
	if string(fields["selectedReplyID"]) == string(choice) {
		return payload, nil
	}
	fields["selectedReplyID"] = choice
	return s.writeMessageFields(conversationID, promptID, fields)
}

// SetReplyAttachments updates only generated-file metadata on a completed reply.
func (s *LocalStore) SetReplyAttachments(conversationID, messageID, attachments string, unavailable int) error {
	var files []backupAttachment
	if unavailable < 0 || json.Unmarshal([]byte(attachments), &files) != nil {
		return errors.New("invalid reply attachments")
	}
	if err := make(zipFiles).add(files); err != nil {
		return err
	}
	return s.transaction(true, func() error {
		rows, err := s.run(`SELECT payload FROM message
			WHERE conversation_id=? AND id=? AND json_extract(payload,'$.role')='assistant'`, conversationID, messageID)
		if err != nil {
			return err
		}
		if len(rows) == 0 {
			return errors.New("reply does not exist")
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(rows[0]), &fields); err != nil {
			return err
		}
		if len(files) > 0 {
			fields["attachments"] = json.RawMessage(attachments)
		} else {
			delete(fields, "attachments")
		}
		if unavailable > 0 {
			fields["unavailableAttachments"] = json.RawMessage(strconv.Itoa(unavailable))
		} else {
			delete(fields, "unavailableAttachments")
		}
		_, err = s.writeMessageFields(conversationID, messageID, fields)
		return err
	})
}

func (s *LocalStore) writeMessageFields(conversationID, messageID string, fields map[string]json.RawMessage) (string, error) {
	updated, err := json.Marshal(fields)
	if err != nil {
		return "", err
	}
	payload, err := s.sanitizeMessageReferences(conversationID, string(updated))
	if err != nil {
		return "", err
	}
	deleted, err := s.deletedMessage(conversationID, messageID)
	if err != nil {
		return "", err
	}
	if deleted {
		return "", errors.New("message_was_deleted")
	}
	if _, err := s.run("UPDATE message SET payload=? WHERE id=? AND conversation_id=?", payload, messageID, conversationID); err != nil {
		return "", err
	}
	return payload, s.stageRecord("m-"+messageID, "message", conversationID, payload)
}

const replyChoiceMigration = "message_reply_choices_v1"

func (s *LocalStore) migrateReplyChoices() error {
	return s.transaction(true, func() error {
		seen, err := s.run("SELECT value FROM metadata WHERE key=?", replyChoiceMigration)
		if err != nil || len(seen) > 0 {
			return err
		}
		rows, err := s.run(`SELECT json_object('conversation',c.id,'prompt',m.id,'reply',choice.value,'payload',m.payload)
			FROM conversation c JOIN json_each(c.header,'$.selectedReplies') choice
			JOIN message m ON m.conversation_id=c.id AND m.id=choice.key
			WHERE json_type(c.header,'$.selectedReplies')='object' AND choice.type='text'
			AND json_extract(m.payload,'$.role')='user' AND json_extract(m.payload,'$.selectedReplyID') IS NULL`)
		if err != nil {
			return err
		}
		for _, row := range rows {
			var choice struct{ Conversation, Prompt, Reply, Payload string }
			if err := json.Unmarshal([]byte(row), &choice); err != nil {
				return err
			}
			if validNodeUUID(choice.Reply) {
				if _, err := s.writeReplyChoice(choice.Conversation, choice.Prompt, choice.Reply, choice.Payload); err != nil {
					return err
				}
			}
		}
		_, err = s.run("INSERT INTO metadata(key,value) VALUES (?, '1')", replyChoiceMigration)
		return err
	})
}

func (s *LocalStore) replyParent(conversationID, replyID string) (string, error) {
	rows, err := s.run(`SELECT json_object('id',id,'role',json_extract(payload,'$.role'),'replyTo',json_extract(payload,'$.replyTo'))
		FROM message WHERE conversation_id=? ORDER BY json_extract(payload,'$.date'),ordering`, conversationID)
	if err != nil {
		return "", err
	}
	parent := ""
	for _, row := range rows {
		var message struct{ ID, Role, ReplyTo string }
		if err := json.Unmarshal([]byte(row), &message); err != nil {
			return "", err
		}
		if message.ID == replyID && message.Role == "assistant" {
			if message.ReplyTo != "" {
				return message.ReplyTo, nil
			}
			return parent, nil
		}
		if message.Role == "user" {
			parent = message.ID
		}
	}
	return "", errors.New("reply does not exist")
}

func (s *LocalStore) Delete(id string) error {
	return s.transaction(true, func() error {
		if _, err := s.run("DELETE FROM conversation WHERE id=?", id); err != nil {
			return err
		}
		if C.sqlite3_changes(s.db) == 0 {
			return nil
		}
		if _, err := s.run("DELETE FROM replica WHERE conversation=? AND kind='message'", id); err != nil {
			return err
		}
		if err := s.removeToolTraceOwners(id); err != nil {
			return err
		}
		return s.stageRecord("c-"+id, "deleted", id, "")
	})
}
