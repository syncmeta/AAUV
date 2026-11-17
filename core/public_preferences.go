package aauvcore

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"unicode"
)

const (
	publicProfileRecord       = "p-profile"
	publicProfileKind         = "profile"
	publicModelServicesRecord = "p-model-services"
	publicModelServicesKind   = "model_services"
	publicPreferencesMirror   = "public_preferences_mirror_v1"
	publicPreferencesPending  = "public_preferences_publication_v1"
	publicPublicationLimit    = 64
	publicCatalogMaximumBytes = 4 << 20
)

var errInvalidPublicPreferences = errors.New("invalid_public_preferences")
var errPublicPreferencesChanged = errors.New("public_preferences_changed")

// RawMessage distinguishes absent values from an explicitly empty catalog.
// Every non-nil value here has already been validated and canonically encoded.
type publicPreferenceState struct {
	Profile       json.RawMessage `json:"profile,omitempty"`
	ModelServices json.RawMessage `json:"modelServices,omitempty"`
}

type publicDisplayProfile struct {
	Name       string `json:"name"`
	AvatarSeed string `json:"avatarSeed"`
}

type publicServiceModel struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type publicModelService struct {
	Name            string               `json:"name"`
	LoginMethod     string               `json:"loginMethod"`
	Endpoint        string               `json:"endpoint"`
	APIProtocol     string               `json:"apiProtocol"`
	ChatGPTClientID *string              `json:"chatGPTClientID,omitempty"`
	Models          []publicServiceModel `json:"models"`
}

// PublicPreferences returns the durable Core projection. It never reads a
// platform cache, credential vault, active account selection or node settings.
func (s *LocalStore) PublicPreferences() (string, error) {
	var result string
	err := s.transaction(false, func() error {
		state, err := s.publicPreferencesLocked()
		if err != nil {
			return err
		}
		result, err = encodePublicPreferenceState(state)
		return err
	})
	return result, err
}

// PreparePublicPreferencesPublication durably offers the current projection
// without interpreting any platform cache as a new local edit. Retry callers
// use it after a failed publication CAS. Earlier offers remain recognizable if
// the process exits before replacing the last published cache value.
func (s *LocalStore) PreparePublicPreferencesPublication() (string, error) {
	var result string
	err := s.transaction(true, func() error {
		projection, err := s.publicPreferencesLocked()
		if err != nil {
			return err
		}
		if err := s.recordPublicPreferencesPublicationLocked(projection); err != nil {
			return err
		}
		result, err = encodePublicPreferenceState(projection)
		return err
	})
	return result, err
}

// ReconcilePublicPreferences records only changes from the last observed local
// cache. The first observation can seed an absent record at clock 1, so a fresh
// device's fallback cannot replace an existing remote value. Missing/null fields
// express no intent; modelServices:[] is the explicit catalog clear operation.
func (s *LocalStore) ReconcilePublicPreferences(local string) (string, error) {
	incoming, err := decodePublicPreferenceState(local)
	if err != nil {
		return "", err
	}
	mirrorJSON, err := encodePublicPreferenceState(incoming)
	if err != nil {
		return "", err
	}
	var result string
	err = s.transaction(true, func() error {
		current, err := s.publicPreferencesLocked()
		if err != nil {
			return err
		}
		rows, err := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesMirror)
		if err != nil {
			return err
		}
		first := len(rows) == 0
		var mirror publicPreferenceState
		if !first {
			mirror, err = decodePublicPreferenceState(rows[0])
			if err != nil {
				return err
			}
		}
		pending, err := s.publicPreferencesPublicationLocked()
		if err != nil {
			return err
		}
		fields := []struct {
			name, kind            string
			local, before, stored json.RawMessage
			publication           []string
		}{
			{publicProfileRecord, publicProfileKind, incoming.Profile, mirror.Profile, current.Profile, pending.Profile},
			{publicModelServicesRecord, publicModelServicesKind, incoming.ModelServices, mirror.ModelServices, current.ModelServices, pending.ModelServices},
		}
		for _, field := range fields {
			if field.local == nil {
				continue
			}
			if first {
				if field.stored == nil {
					if err := s.stageRecordAt(field.name, field.kind, "", string(field.local), 1); err != nil {
						return err
					}
				}
			} else if !bytes.Equal(field.local, field.before) && !bytes.Equal(field.local, field.stored) &&
				!publicPreferencePublicationContains(field.publication, field.local) {
				// A cache publication that completed before a crash but before
				// Mark is already equal to Core: do not churn its clock/outbox.
				if err := s.stageRecord(field.name, field.kind, "", string(field.local)); err != nil {
					return err
				}
			}
		}
		beforeMirror, err := encodePublicPreferenceState(mirror)
		if err != nil {
			return err
		}
		if first || beforeMirror != mirrorJSON {
			if _, err := s.run(`INSERT INTO metadata(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`, publicPreferencesMirror, mirrorJSON); err != nil {
				return err
			}
		}
		projection, err := s.publicPreferencesLocked()
		if err != nil {
			return err
		}
		if err := s.recordPublicPreferencesPublicationLocked(projection); err != nil {
			return err
		}
		result, err = encodePublicPreferenceState(projection)
		return err
	})
	return result, err
}

// MarkPublicPreferencesPublished is a semantic CAS after the platform has
// successfully mirrored the projection. A changed projection must be republished
// directly; callers must not reinterpret an obsolete publication as a new edit.
func (s *LocalStore) MarkPublicPreferencesPublished(snapshot string) error {
	published, err := decodePublicPreferenceState(snapshot)
	if err != nil {
		return err
	}
	canonical, err := encodePublicPreferenceState(published)
	if err != nil {
		return err
	}
	return s.transaction(true, func() error {
		current, err := s.publicPreferencesLocked()
		if err != nil {
			return err
		}
		actual, err := encodePublicPreferenceState(current)
		if err != nil {
			return err
		}
		if actual != canonical {
			return errPublicPreferencesChanged
		}
		rows, err := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesMirror)
		if err != nil {
			return err
		}
		mirrorSame := false
		if len(rows) > 0 {
			if previous, err := decodePublicPreferenceState(rows[0]); err == nil {
				text, err := encodePublicPreferenceState(previous)
				mirrorSame = err == nil && text == canonical
			}
		}
		if !mirrorSame {
			if _, err := s.run(`INSERT INTO metadata(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`, publicPreferencesMirror, canonical); err != nil {
				return err
			}
		}
		// Only a successful semantic CAS confirms the cache is current enough
		// to retire all prior offers, including partially published snapshots.
		_, err = s.run("DELETE FROM metadata WHERE key=?", publicPreferencesPending)
		return err
	})
}

// The journal retains per-field digests rather than multiple 4MiB catalogs.
// Keeping all unmarked offers (not just the newest) covers prepare-C/crash
// while defaults still contain B, and half-published profile/catalog pairs.
type publicPreferencePublication struct {
	Profile       []string `json:"profile,omitempty"`
	ModelServices []string `json:"modelServices,omitempty"`
}

func publicPreferencePublicationDigest(value json.RawMessage) string {
	digest := sha256.Sum256(value)
	return hex.EncodeToString(digest[:])
}

func publicPreferencePublicationContains(values []string, value json.RawMessage) bool {
	if value == nil {
		return false
	}
	needle := publicPreferencePublicationDigest(value)
	for _, candidate := range values {
		if candidate == needle {
			return true
		}
	}
	return false
}

func (s *LocalStore) publicPreferencesPublicationLocked() (publicPreferencePublication, error) {
	var result publicPreferencePublication
	rows, err := s.run("SELECT value FROM metadata WHERE key=?", publicPreferencesPending)
	if err != nil || len(rows) == 0 {
		return result, err
	}
	if len(rows[0]) > 16384 || validateJSONBoundary([]byte(rows[0]), nil) != nil {
		return result, errInvalidPublicPreferences
	}
	fields, err := publicPreferenceObject([]byte(rows[0]), "profile", "modelServices")
	if err != nil {
		return result, err
	}
	for key, raw := range fields {
		var values []string
		if json.Unmarshal(raw, &values) != nil || values == nil || len(values) > publicPublicationLimit {
			return result, errInvalidPublicPreferences
		}
		seen := map[string]bool{}
		for _, value := range values {
			decoded, err := hex.DecodeString(value)
			if err != nil || len(decoded) != sha256.Size || len(value) != 64 || strings.ToLower(value) != value || seen[value] {
				return result, errInvalidPublicPreferences
			}
			seen[value] = true
		}
		if key == "profile" {
			result.Profile = values
		} else {
			result.ModelServices = values
		}
	}
	return result, nil
}

func (s *LocalStore) recordPublicPreferencesPublicationLocked(state publicPreferenceState) error {
	pending, err := s.publicPreferencesPublicationLocked()
	if err != nil {
		return err
	}
	changed := false
	for _, field := range []struct {
		value json.RawMessage
		list  *[]string
	}{{state.Profile, &pending.Profile}, {state.ModelServices, &pending.ModelServices}} {
		if field.value == nil || publicPreferencePublicationContains(*field.list, field.value) {
			continue
		}
		if len(*field.list) >= publicPublicationLimit {
			return errors.New("public_preferences_publication_limit")
		}
		*field.list = append(*field.list, publicPreferencePublicationDigest(field.value))
		changed = true
	}
	if !changed {
		return nil
	}
	encoded, err := json.Marshal(pending)
	if err != nil {
		return err
	}
	_, err = s.run(`INSERT INTO metadata(key,value) VALUES(?,?)
        ON CONFLICT(key) DO UPDATE SET value=excluded.value`, publicPreferencesPending, string(encoded))
	return err
}

func (s *LocalStore) publicPreferencesLocked() (publicPreferenceState, error) {
	var state publicPreferenceState
	rows, err := s.run("SELECT "+replicaJSON+" FROM replica WHERE name IN (?,?) ORDER BY name", publicProfileRecord, publicModelServicesRecord)
	if err != nil {
		return state, err
	}
	for _, raw := range rows {
		var record replicaRecord
		if json.Unmarshal([]byte(raw), &record) != nil || validatePublicPreferenceRecord(record) != nil {
			return state, errInvalidPublicPreferences
		}
		payload, err := canonicalPublicPreferencePayload(record.Kind, []byte(record.Payload))
		if err != nil {
			return state, err
		}
		if record.Kind == publicProfileKind {
			state.Profile = payload
		} else {
			state.ModelServices = payload
		}
	}
	return state, nil
}

// validatePublicPreferenceRecord validates the entire allowlisted payload before
// a replica is persisted. Unknown nested fields, including credentials, fail.
func validatePublicPreferenceRecord(record replicaRecord) error {
	if record.Conversation != "" ||
		!(record.Name == publicProfileRecord && record.Kind == publicProfileKind ||
			record.Name == publicModelServicesRecord && record.Kind == publicModelServicesKind) {
		return errInvalidPublicPreferences
	}
	_, err := canonicalPublicPreferencePayload(record.Kind, []byte(record.Payload))
	return err
}

func decodePublicPreferenceState(input string) (publicPreferenceState, error) {
	var state publicPreferenceState
	if len(input) > publicCatalogMaximumBytes+4096 || validateJSONBoundary([]byte(input), nil) != nil {
		return state, errInvalidPublicPreferences
	}
	fields, err := publicPreferenceObject([]byte(input), "profile", "modelServices")
	if err != nil {
		return state, err
	}
	for key, raw := range fields {
		if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			continue
		}
		kind := publicProfileKind
		if key == "modelServices" {
			kind = publicModelServicesKind
		}
		payload, err := canonicalPublicPreferencePayload(kind, raw)
		if err != nil {
			return state, err
		}
		if key == "profile" {
			state.Profile = payload
		} else {
			state.ModelServices = payload
		}
	}
	return state, nil
}

func encodePublicPreferenceState(state publicPreferenceState) (string, error) {
	data, err := json.Marshal(state)
	return string(data), err
}

func publicPreferenceObject(raw []byte, allowed ...string) (map[string]json.RawMessage, error) {
	var result map[string]json.RawMessage
	if json.Unmarshal(raw, &result) != nil || result == nil {
		return nil, errInvalidPublicPreferences
	}
	for key := range result {
		known := false
		for _, permitted := range allowed {
			known = known || key == permitted
		}
		if !known {
			return nil, errInvalidPublicPreferences
		}
	}
	return result, nil
}

func publicPreferenceString(raw json.RawMessage, fallback *string) (string, error) {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		if fallback != nil {
			return *fallback, nil
		}
		return "", errInvalidPublicPreferences
	}
	var value string
	if json.Unmarshal(raw, &value) != nil {
		return "", errInvalidPublicPreferences
	}
	return value, nil
}

func canonicalPublicPreferencePayload(kind string, raw []byte) (json.RawMessage, error) {
	if len(raw) == 0 || len(raw) > publicCatalogMaximumBytes || validateJSONBoundary(raw, nil) != nil {
		return nil, errInvalidPublicPreferences
	}
	if kind == publicProfileKind {
		fields, err := publicPreferenceObject(raw, "name", "avatarSeed")
		if err != nil {
			return nil, err
		}
		name, err := publicPreferenceString(fields["name"], nil)
		if err != nil {
			return nil, err
		}
		seed, err := publicPreferenceString(fields["avatarSeed"], nil)
		if err != nil {
			return nil, err
		}
		name = strings.TrimSpace(name)
		if name == "" || publicPreferenceControls(name) || !validNodeUUID(seed) {
			return nil, errInvalidPublicPreferences
		}
		return json.Marshal(publicDisplayProfile{Name: name, AvatarSeed: seed})
	}
	if kind != publicModelServicesKind {
		return nil, errInvalidPublicPreferences
	}
	var values []json.RawMessage
	if json.Unmarshal(raw, &values) != nil || values == nil || len(values) > 128 {
		return nil, errInvalidPublicPreferences
	}
	result := make([]publicModelService, 0, len(values))
	seen := map[string]bool{}
	for _, value := range values {
		service, err := decodePublicModelService(value)
		if err != nil {
			return nil, err
		}
		identity := service.LoginMethod + "\x00" + service.Endpoint + "\x00" + service.APIProtocol
		if service.ChatGPTClientID != nil {
			identity += "\x00" + *service.ChatGPTClientID
		}
		if seen[identity] {
			return nil, errInvalidPublicPreferences
		}
		seen[identity] = true
		result = append(result, service)
	}
	data, err := json.Marshal(result)
	if err != nil || len(data) > publicCatalogMaximumBytes {
		return nil, errInvalidPublicPreferences
	}
	return data, nil
}

// Display-name grapheme limits belong to Swift String.count validation. Core
// keeps the document byte bounds and control/nonempty checks without confusing
// Unicode scalar count with user-perceived characters. Model IDs remain bounded
// separately in UTF-8 bytes.
func publicPreferenceControls(value string) bool {
	return strings.ContainsFunc(value, unicode.IsControl)
}

func decodePublicModelService(raw []byte) (publicModelService, error) {
	var result publicModelService
	fields, err := publicPreferenceObject(raw, "name", "loginMethod", "endpoint", "apiProtocol", "chatGPTClientID", "models")
	if err != nil {
		return result, err
	}
	if result.Name, err = publicPreferenceString(fields["name"], nil); err != nil {
		return result, err
	}
	if result.LoginMethod, err = publicPreferenceString(fields["loginMethod"], nil); err != nil {
		return result, err
	}
	if result.Endpoint, err = publicPreferenceString(fields["endpoint"], nil); err != nil {
		return result, err
	}
	responses := "responses"
	if result.APIProtocol, err = publicPreferenceString(fields["apiProtocol"], &responses); err != nil {
		return result, err
	}
	result.Name = strings.TrimSpace(result.Name)
	if result.Name == "" || publicPreferenceControls(result.Name) {
		return result, errInvalidPublicPreferences
	}
	result.Endpoint, err = publicPreferenceEndpoint(result.Endpoint)
	if err != nil {
		return result, err
	}
	if cid := fields["chatGPTClientID"]; len(cid) > 0 && !bytes.Equal(bytes.TrimSpace(cid), []byte("null")) {
		value, err := publicPreferenceString(cid, nil)
		if err != nil || !publicPreferenceNativeCID(value) {
			return result, errInvalidPublicPreferences
		}
		result.ChatGPTClientID = &value
	}
	switch result.LoginMethod {
	case "byok":
		result.APIProtocol = strings.TrimSpace(result.APIProtocol)
		if result.APIProtocol != "responses" && result.APIProtocol != "chat_completions" && result.APIProtocol != "anthropic_messages" {
			return result, errInvalidPublicPreferences
		}
		result.ChatGPTClientID = nil
	case "chatgpt":
		if result.ChatGPTClientID == nil {
			return result, errInvalidPublicPreferences
		}
		result.Endpoint, result.APIProtocol = "https://api.openai.com/v1", "responses"
	case "copilot":
		result.Endpoint, result.APIProtocol = "https://github.com", "responses"
		result.ChatGPTClientID = nil
	default:
		return result, errInvalidPublicPreferences
	}
	var models []json.RawMessage
	if rawModels := fields["models"]; len(rawModels) > 0 && !bytes.Equal(bytes.TrimSpace(rawModels), []byte("null")) {
		if json.Unmarshal(rawModels, &models) != nil || models == nil || len(models) > 2048 {
			return result, errInvalidPublicPreferences
		}
	}
	result.Models = make([]publicServiceModel, 0, len(models))
	seen := map[string]bool{}
	for _, rawModel := range models {
		modelFields, err := publicPreferenceObject(rawModel, "id", "name")
		if err != nil {
			return result, err
		}
		id, err := publicPreferenceString(modelFields["id"], nil)
		if err != nil {
			return result, err
		}
		name, err := publicPreferenceString(modelFields["name"], &id)
		if err != nil {
			return result, err
		}
		id, name = strings.TrimSpace(id), strings.TrimSpace(name)
		if id == "" || len(id) > 512 || publicPreferenceControls(id+name) {
			return result, errInvalidPublicPreferences
		}
		if name == "" {
			name = id
		}
		if !seen[id] {
			result.Models = append(result.Models, publicServiceModel{ID: id, Name: name})
			seen[id] = true
		}
	}
	return result, nil
}

func publicPreferenceNativeCID(value string) bool {
	if len(value) <= len("oaiapp_") || len(value) > 256 || !strings.HasPrefix(value, "oaiapp_") {
		return false
	}
	for _, c := range []byte(value) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func publicPreferenceEndpoint(input string) (string, error) {
	if len(input) > 4096 {
		return "", errInvalidPublicPreferences
	}
	input = strings.TrimSpace(input)
	u, err := url.Parse(input)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(input, "#") || u.Opaque != "" {
		return "", errInvalidPublicPreferences
	}
	host := strings.ToLower(u.Hostname())
	if host == "aauv.invalid" || host == "aauv.invalid." ||
		(u.Scheme != "https" && !(u.Scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1"))) {
		return "", errInvalidPublicPreferences
	}
	u.Host = strings.ToLower(u.Host)
	escaped := strings.TrimRight(u.EscapedPath(), "/")
	u.Path, err = url.PathUnescape(escaped)
	if err != nil {
		return "", errInvalidPublicPreferences
	}
	u.RawPath = escaped
	return u.String(), nil
}
