package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

const localToolTraceLimit = 128 * 1024
const localToolTraceCalls = 64

type localToolTraceEntry struct {
	Sequence       int     `json:"sequence"`
	ID             string  `json:"id"`
	Function       string  `json:"function"`
	State          string  `json:"state"`
	Query          *string `json:"query,omitempty"`
	QueryTruncated *bool   `json:"queryTruncated,omitempty"`
	SkillName      *string `json:"skillName,omitempty"`
	Quantity       *int    `json:"quantity,omitempty"`
	Failure        *string `json:"failure,omitempty"`
}
type localToolTrace struct {
	Version     int                   `json:"version"`
	RequestID   string                `json:"requestID"`
	RunRevision string                `json:"runRevision"`
	Entries     []localToolTraceEntry `json:"entries"`
}

var traceURL = regexp.MustCompile(`(?i)(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>"']+`)
var traceBearer = regexp.MustCompile(`(?i)\b(?:authorization["']?\s*[:=]\s*["']?(?:(?:bearer|basic)\s+)?|(?:bearer|basic)\s*[:=]?\s+)[^\s,;"']+`)
var traceAssigned = regexp.MustCompile(`(?i)\b(?:access_token|refresh_token|client_secret|api[_-]?key|password)["']?\s*[:=]\s*["']?(?:(?:bearer|basic)\s+)?[^\s,;"']+`)
var traceToken = regexp.MustCompile(`\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,})\b`)

func traceStrictDecode(raw []byte, value any) error {
	if !utf8.Valid(raw) || validateJSONBoundary(raw, nil) != nil {
		return errors.New("invalid_local_tool_trace")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if decoder.Decode(value) != nil {
		return errors.New("invalid_local_tool_trace")
	}
	return nil
}
func traceQuery(value string) (string, bool) {
	if len(value) > 4096 || utf8.RuneCountInString(value) > 1024 {
		return "", false
	}
	// Invisible formatting must not split an authorization prefix before the
	// redactor sees it. The real tool query is never changed, only this preview.
	value = strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, value)
	// Remove a raw URL as one span before controls could split its path and
	// leave a credential-looking tail behind. Then normalize separators before
	// recognizing authorization/token shapes, including NUL and Unicode spaces.
	value = traceURL.ReplaceAllString(value, "[omitted]")
	value = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.IsSpace(r) {
			return ' '
		}
		return r
	}, value)
	for _, pattern := range []*regexp.Regexp{traceURL, traceBearer, traceAssigned, traceToken} {
		value = pattern.ReplaceAllString(value, "[omitted]")
	}
	value = strings.Join(strings.Fields(value), " ")
	runes := []rune(value)
	if len(runes) > 256 {
		return strings.TrimSpace(string(runes[:256])), true
	}
	return value, false
}
func decodeTraceEntry(raw json.RawMessage) (localToolTraceEntry, error) {
	return decodeTraceEntryMode(raw, true)
}
func decodeTraceEvent(raw json.RawMessage) (localToolTraceEntry, error) {
	return decodeTraceEntryMode(raw, false)
}
func decodeTraceEntryMode(raw json.RawMessage, stored bool) (localToolTraceEntry, error) {
	var entry localToolTraceEntry
	if len(raw) > localToolTraceLimit || traceStrictDecode(raw, &entry) != nil {
		return entry, errors.New("invalid_local_tool_trace")
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(raw, &fields)
	_, hasSequence := fields["sequence"]
	if stored != hasSequence || (stored && bytes.Equal(bytes.TrimSpace(fields["sequence"]), []byte("null"))) {
		return entry, errors.New("invalid_local_tool_trace")
	}
	for _, key := range []string{"query", "queryTruncated", "skillName", "quantity", "failure"} {
		if bytes.Equal(bytes.TrimSpace(fields[key]), []byte("null")) {
			return entry, errors.New("invalid_local_tool_trace")
		}
	}
	return canonicalTraceEntry(entry)
}
func canonicalTraceEntry(entry localToolTraceEntry) (localToolTraceEntry, error) {
	invalid := errors.New("invalid_local_tool_trace")
	if entry.Sequence < 0 || entry.Sequence >= localToolTraceCalls {
		return entry, invalid
	}
	if !validNodeUUID(entry.ID) {
		return entry, invalid
	}
	entry.ID = strings.ToLower(entry.ID)
	switch entry.Function {
	case "search_chat_history", "create_skill", "read_attachment", "send_images", "delegate_to_specialist":
	default:
		return entry, invalid
	}
	switch entry.State {
	case "running", "succeeded", "partial", "failed", "interrupted":
	default:
		return entry, invalid
	}
	if entry.Query != nil || entry.QueryTruncated != nil {
		if entry.Function != "search_chat_history" || entry.Query == nil {
			return entry, invalid
		}
		preview, truncated := traceQuery(*entry.Query)
		if preview == "" {
			entry.Query = nil
			entry.QueryTruncated = nil
		} else {
			entry.Query = &preview
			if truncated || (entry.QueryTruncated != nil && *entry.QueryTruncated) {
				yes := true
				entry.QueryTruncated = &yes
			} else {
				entry.QueryTruncated = nil
			}
		}
	}
	if entry.SkillName != nil {
		if entry.Function != "create_skill" || utf8.RuneCountInString(*entry.SkillName) > 80 || !storeToolSkillNamePattern.MatchString(*entry.SkillName) {
			return entry, invalid
		}
	}
	if entry.Quantity != nil {
		limit := 4194304
		switch entry.Function {
		case "search_chat_history":
			limit = 30
		case "send_images":
			limit = 5
		case "create_skill":
			return entry, invalid
		}
		if *entry.Quantity < 0 || *entry.Quantity > limit {
			return entry, invalid
		}
	}
	if entry.Failure != nil {
		if entry.State != "failed" && entry.State != "interrupted" {
			return entry, invalid
		}
		switch *entry.Failure {
		case "invalid_input", "unavailable", "timeout", "limit", "tool_failed":
		default:
			return entry, invalid
		}
	}
	if entry.State == "running" && (entry.Quantity != nil || entry.Failure != nil) {
		return entry, invalid
	}
	if entry.State == "partial" && (entry.Function != "send_images" || entry.Quantity == nil || *entry.Quantity == 0) {
		return entry, invalid
	}
	return entry, nil
}
func decodeLocalToolTrace(raw json.RawMessage) (localToolTrace, error) {
	var trace localToolTrace
	if len(raw) > localToolTraceLimit || traceStrictDecode(raw, &trace) != nil || trace.Version != 1 || !validTraceRevision(trace.RunRevision) || !validNodeUUID(trace.RequestID) || trace.Entries == nil || len(trace.Entries) > localToolTraceCalls {
		return trace, errors.New("invalid_local_tool_trace")
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(raw, &fields)
	var entries []json.RawMessage
	if json.Unmarshal(fields["entries"], &entries) != nil {
		return trace, errors.New("invalid_local_tool_trace")
	}
	trace.RequestID = strings.ToLower(trace.RequestID)
	trace.Entries = make([]localToolTraceEntry, 0, len(entries))
	seen := map[string]bool{}
	for _, entryRaw := range entries {
		entry, err := decodeTraceEntry(entryRaw)
		if err != nil || seen[entry.ID] {
			return trace, errors.New("invalid_local_tool_trace")
		}
		seen[entry.ID] = true
		trace.Entries = append(trace.Entries, entry)
	}
	sort.Slice(trace.Entries, func(i, j int) bool {
		a, b := trace.Entries[i], trace.Entries[j]
		if a.Sequence != b.Sequence {
			return a.Sequence < b.Sequence
		}
		return a.ID < b.ID
	})
	return trace, nil
}
func encodeLocalToolTrace(trace localToolTrace) (json.RawMessage, error) {
	data, err := json.Marshal(trace)
	if err != nil || len(data) > localToolTraceLimit {
		return nil, errors.New("invalid_local_tool_trace")
	}
	return data, nil
}
func canonicalMessageToolTrace(payload string) (string, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal([]byte(payload), &fields) != nil || fields == nil {
		return "", errors.New("invalid message payload")
	}
	raw, ok := fields["localToolTrace"]
	if !ok {
		return payload, nil
	}
	var role string
	_ = json.Unmarshal(fields["role"], &role)
	if role != "user" {
		return "", errors.New("invalid_local_tool_trace")
	}
	trace, err := decodeLocalToolTrace(raw)
	if err != nil {
		return "", err
	}
	fields["localToolTrace"], err = encodeLocalToolTrace(trace)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(fields)
	return string(data), err
}
func traceHasRunning(trace localToolTrace) bool {
	for _, entry := range trace.Entries {
		if entry.State == "running" {
			return true
		}
	}
	return false
}
func interruptTrace(trace *localToolTrace) bool {
	changed := false
	for i := range trace.Entries {
		if trace.Entries[i].State == "running" {
			trace.Entries[i].State = "interrupted"
			changed = true
		}
	}
	return changed
}
