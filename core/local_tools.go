package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	localToolNamespace        = "aauv"
	maxLocalCalls             = 32
	maxUsedLocalCallIDs       = 128
	maxContinuationItems      = 512
	maxContinuationBytes      = 64 * 1024 * 1024
	maxFunctionArgumentsBytes = 64 * 1024 * 1024
	maxFunctionOutputBytes    = 4 * 1024 * 1024
)

type localToolPolicy struct {
	names       []string
	allowed     map[string]bool
	namespace   string
	usedCallIDs map[string]bool
}

type localFunctionCall struct {
	ID        string `json:"id,omitempty"`
	CallID    string `json:"call_id"`
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Arguments string `json:"arguments"`
}

func newLocalToolPolicy(names []string, namespace string) (*localToolPolicy, error) {
	if namespace != "" && namespace != localToolNamespace {
		return nil, errors.New("unsupported_local_tool_namespace")
	}
	policy := &localToolPolicy{names: append([]string(nil), names...), allowed: map[string]bool{}, namespace: namespace, usedCallIDs: map[string]bool{}}
	for _, name := range names {
		if _, ok := localToolRegistry()[name]; !ok {
			return nil, errors.New("unsupported_local_tool")
		}
		if policy.allowed[name] {
			return nil, errors.New("duplicate_local_tool")
		}
		policy.allowed[name] = true
	}
	return policy, nil
}

// LocalToolDefinitionsJSON exposes only the fixed, enabled function metadata to
// native adapters. It never accepts schemas, URLs, credentials, or handlers.
func LocalToolDefinitionsJSON(namesJSON string) (string, error) {
	if len(namesJSON) > 4096 || validateUniqueJSON([]byte(namesJSON)) != nil {
		return "", errors.New("invalid_local_tool_names")
	}
	var names []string
	if json.Unmarshal([]byte(namesJSON), &names) != nil || names == nil {
		return "", errors.New("invalid_local_tool_names")
	}
	policy, err := newLocalToolPolicy(names, "")
	if err != nil {
		return "", err
	}
	definitions := make([]map[string]any, 0, len(names))
	for _, definition := range policy.definitions() {
		definitions = append(definitions, map[string]any{
			"name": definition["name"], "description": definition["description"], "parameters": definition["parameters"],
		})
	}
	encoded, err := json.Marshal(definitions)
	return string(encoded), err
}

// NewStreamWithLocalTools enables only the exact request's fixed local functions.
// policyJSON must explicitly include namespace: "" for flat BYOK, "aauv" for
// ChatGPT-plan requests. No credentials, arbitrary schemas, or callbacks cross Go.
func NewStreamWithLocalTools(policyJSON string) (*Stream, error) {
	if len(policyJSON) > 16*1024 || validateUniqueJSON([]byte(policyJSON)) != nil {
		return nil, errors.New("invalid_local_tool_policy")
	}
	var input struct {
		Names       []string `json:"local_tools"`
		Namespace   *string  `json:"namespace"`
		UsedCallIDs []string `json:"used_call_ids,omitempty"`
	}
	decoder := json.NewDecoder(strings.NewReader(policyJSON))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || input.Namespace == nil {
		return nil, errors.New("invalid_local_tool_policy")
	}
	policy, err := newLocalToolPolicy(input.Names, *input.Namespace)
	if err != nil {
		return nil, err
	}
	if len(input.UsedCallIDs) > maxUsedLocalCallIDs {
		return nil, errors.New("invalid_used_local_tool_call_ids")
	}
	for _, id := range input.UsedCallIDs {
		if !safeCallIdentifier(id, 64) || policy.usedCallIDs[id] {
			return nil, errors.New("invalid_used_local_tool_call_ids")
		}
		policy.usedCallIDs[id] = true
	}
	return &Stream{localTools: policy}, nil
}

func localToolRegistry() map[string]map[string]any {
	text := func(description string, max int) map[string]any {
		return map[string]any{"type": "string", "description": description, "minLength": 1, "maxLength": max}
	}
	optionalText := func(description string) map[string]any {
		return map[string]any{"type": []string{"string", "null"}, "description": description}
	}
	function := func(name, description string, properties map[string]any, required []string) map[string]any {
		return map[string]any{"type": "function", "name": name, "description": description, "strict": true,
			"parameters": map[string]any{"type": "object", "properties": properties, "required": required, "additionalProperties": false}}
	}
	return map[string]map[string]any{
		"search_chat_history": function("search_chat_history", "Search this conversation's local history. Supply at least one nonempty query, since, or until. Null means omitted. Results exclude deleted/log entries; default limit 10, maximum 30.", map[string]any{
			"query": optionalText("Message substring expression: whitespace means AND, OR joins alternatives, - excludes, and double quotes group a phrase. ASCII case-insensitive; CJK substrings match literally."),
			"since": optionalText("Inclusive start time in ISO 8601."),
			"until": optionalText("Exclusive end time in ISO 8601."),
			"limit": map[string]any{"type": []string{"integer", "null"}, "minimum": 1, "maximum": 30},
		}, []string{"query", "since", "until", "limit"}),
		"create_skill": function("create_skill", "Create a local skill and enable it for this conversation on the next request.", map[string]any{
			"name":        map[string]any{"type": "string", "minLength": 1, "maxLength": 80, "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$"},
			"description": map[string]any{"type": "string", "maxLength": 2000},
			"body":        text("Skill instructions, stored locally.", 65536),
		}, []string{"name", "description", "body"}),
		"read_attachment": function("read_attachment", "Read an attachment belonging to this conversation by its UUID or unique ID prefix and answer a question about it.", map[string]any{
			"attachment_id": text("Attachment UUID or unique prefix (normally at least 8 characters).", 256),
			"question":      text("Question about the attachment.", 500),
		}, []string{"attachment_id", "question"}),
		"send_images": function("send_images", "Send 1 to 5 existing images as conversation attachments. Accepts HTTPS image URLs or data:image PNG/JPEG/WebP/GIF URLs, not an image-generation prompt. Each image is limited to 25 MB by the local executor.", map[string]any{
			"images": map[string]any{"type": "array", "items": map[string]any{"type": "string", "minLength": 1}, "minItems": 1, "maxItems": 5},
		}, []string{"images"}),
		"delegate_to_specialist": function("delegate_to_specialist", "Ask one configured cloud model a bounded standalone question. The specialist receives no conversation history or tools; this is not a Crew task.", map[string]any{
			"model_slug": text("Configured cloud model identifier.", 512),
			"prompt":     text("Standalone question for the cloud model.", 8000),
		}, []string{"model_slug", "prompt"}),
	}
}

func (policy *localToolPolicy) definitions() []map[string]any {
	if len(policy.names) == 0 {
		return nil
	}
	registry := localToolRegistry()
	functions := make([]map[string]any, 0, len(policy.names))
	for _, name := range policy.names {
		functions = append(functions, registry[name])
	}
	if policy.namespace == "" {
		return functions
	}
	return []map[string]any{{"type": "namespace", "name": policy.namespace, "description": "AAUV's explicitly enabled, conversation-scoped local functions.", "tools": functions}}
}

func readString(object map[string]json.RawMessage, key string, required bool) (string, error) {
	raw, ok := object[key]
	if !ok && !required {
		return "", nil
	}
	var value string
	if !ok || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &value) != nil {
		return "", errors.New("invalid_local_tool_item")
	}
	return value, nil
}

func safeCallIdentifier(value string, max int) bool {
	if len(value) == 0 || len(value) > max {
		return false
	}
	for _, c := range value {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func (policy *localToolPolicy) parseCall(raw json.RawMessage) (localFunctionCall, error) {
	var call localFunctionCall
	if policy == nil || len(policy.allowed) == 0 {
		return call, errors.New("client_tool_execution_disabled")
	}
	var item map[string]json.RawMessage
	if json.Unmarshal(raw, &item) != nil || item == nil {
		return call, errors.New("invalid_local_tool_call")
	}
	for key := range item {
		switch key {
		case "type", "id", "call_id", "name", "namespace", "arguments", "status", "caller", "async":
		default:
			return call, errors.New("invalid_local_tool_call")
		}
	}
	var err error
	if call.CallID, err = readString(item, "call_id", true); err != nil || !safeCallIdentifier(call.CallID, 64) {
		return call, errors.New("invalid_local_tool_call_id")
	}
	if policy.usedCallIDs[call.CallID] {
		return call, errors.New("duplicate_local_tool_call_id")
	}
	if call.Name, err = readString(item, "name", true); err != nil || !policy.allowed[call.Name] {
		return call, errors.New("local_tool_not_allowed")
	}
	if call.Namespace, err = readString(item, "namespace", false); err != nil || call.Namespace != policy.namespace {
		return call, errors.New("local_tool_namespace_mismatch")
	}
	if call.ID, err = readString(item, "id", false); err != nil || (call.ID != "" && !safeCallIdentifier(call.ID, 256)) {
		return call, errors.New("invalid_local_tool_call")
	}
	status, err := readString(item, "status", false)
	if err != nil || (status != "" && status != "completed") {
		return call, errors.New("incomplete_local_tool_call")
	}
	if caller, ok := item["caller"]; ok {
		var metadata map[string]json.RawMessage
		if json.Unmarshal(caller, &metadata) != nil || len(metadata) != 1 || string(metadata["type"]) != `"direct"` {
			return call, errors.New("local_tool_caller_not_allowed")
		}
	}
	if async, ok := item["async"]; ok && string(bytes.TrimSpace(async)) != "false" {
		return call, errors.New("async_local_tool_not_allowed")
	}
	if call.Arguments, err = readString(item, "arguments", true); err != nil || validateLocalArguments(call.Arguments) != nil {
		return call, errors.New("invalid_local_tool_arguments")
	}
	return call, nil
}

// Only structural safety belongs at the protocol boundary. Correctable business
// errors (unknown fields, wrong field types, invalid dates/names, empty body) are
// returned by the executor as tool results so the model can repair its call.
func validateLocalArguments(encoded string) error {
	if len(encoded) > maxFunctionArgumentsBytes || validateUniqueJSON([]byte(encoded)) != nil {
		return errors.New("invalid_local_tool_arguments")
	}
	var args map[string]json.RawMessage
	if json.Unmarshal([]byte(encoded), &args) != nil || args == nil {
		return errors.New("invalid_local_tool_arguments")
	}
	return nil
}

func knownHostedOutput(kind string) bool {
	return kind == "web_search_call" || kind == "code_interpreter_call" || kind == "image_generation_call"
}

// Validate an opaque item without reconstructing it: encrypted reasoning,
// provider metadata, message phase and annotations must survive round trips.
func validateReplayItem(raw json.RawMessage, policy *localToolPolicy, allowResult bool) (*localFunctionCall, string, error) {
	bad := errors.New("invalid_continuation_item")
	var header struct {
		Type string `json:"type"`
	}
	if json.Unmarshal(raw, &header) != nil {
		return nil, "", bad
	}
	forbidden := map[string]bool{}
	for _, key := range []string{"tools", "instructions", "input", "tool_choice", "additional_tools", "developer", "system"} {
		forbidden[key] = true
	}
	if header.Type != "message" {
		forbidden["role"] = true
	}
	if validateJSONBoundary(raw, forbidden) != nil {
		return nil, "", bad
	}
	if knownHostedOutput(header.Type) {
		// Do not copy a potentially large base64 image into a second RawMessage
		// map. Provider-owned outputs are opaque and never locally executable.
		return nil, "", nil
	}
	var item map[string]json.RawMessage
	if json.Unmarshal(raw, &item) != nil || item == nil {
		return nil, "", bad
	}
	kind, err := readString(item, "type", true)
	if err != nil {
		return nil, "", bad
	}
	switch {
	case kind == "function_call":
		call, err := policy.parseCall(raw)
		return &call, "", err
	case kind == "function_call_output":
		if !allowResult {
			return nil, "", errors.New("client_tool_execution_disabled")
		}
		for key := range item {
			if key != "type" && key != "call_id" && key != "output" {
				return nil, "", bad
			}
		}
		id, err := readString(item, "call_id", true)
		if err != nil || !safeCallIdentifier(id, 64) {
			return nil, "", errors.New("invalid_local_tool_call_id")
		}
		output, err := readString(item, "output", true)
		if err != nil || len(output) > maxFunctionOutputBytes {
			return nil, "", errors.New("invalid_local_tool_output")
		}
		return nil, id, nil
	case kind == "message":
		role, err := readString(item, "role", true)
		if err != nil || role != "assistant" {
			return nil, "", bad
		}
		if phase, ok := item["phase"]; ok {
			var value string
			if json.Unmarshal(phase, &value) != nil || string(phase) == "null" || len(value) > 64 {
				return nil, "", bad
			}
		}
		var content []map[string]json.RawMessage
		if json.Unmarshal(item["content"], &content) != nil || content == nil {
			return nil, "", bad
		}
		for _, part := range content {
			typeName, err := readString(part, "type", true)
			if err != nil {
				return nil, "", bad
			}
			switch typeName {
			case "output_text":
				if _, err := readString(part, "text", true); err != nil {
					return nil, "", bad
				}
			case "refusal":
				if _, err := readString(part, "refusal", true); err != nil {
					return nil, "", bad
				}
			default:
				return nil, "", bad
			}
		}
	case kind == "reasoning":
		if encrypted, ok := item["encrypted_content"]; ok {
			if _, err := readString(item, "encrypted_content", true); (err != nil && string(bytes.TrimSpace(encrypted)) != "null") || len(encrypted) > maxContinuationBytes {
				return nil, "", bad
			}
		}
		for _, key := range []string{"summary", "content"} {
			if raw, ok := item[key]; ok {
				var parts []json.RawMessage
				if json.Unmarshal(raw, &parts) != nil {
					return nil, "", bad
				}
			}
		}
	case knownHostedOutput(kind):
		// Provider-owned outputs are replayed, never handed to a local executor.
	default:
		return nil, "", errors.New("unsupported_continuation_item")
	}
	return nil, "", nil
}

func validateContinuation(items []json.RawMessage, policy *localToolPolicy, credentialKind string) error {
	if len(items) > maxContinuationItems {
		return errors.New("continuation_too_large")
	}
	if len(items) > 0 && (policy == nil || len(policy.allowed) == 0) {
		return errors.New("continuation_requires_local_tools")
	}
	pending := map[string]bool{}
	seen := map[string]bool{}
	total := 0
	for _, raw := range items {
		total += len(raw)
		if total > maxContinuationBytes {
			return errors.New("continuation_too_large")
		}
		call, result, err := validateReplayItem(raw, policy, true)
		if err != nil {
			return err
		}
		if credentialKind == "chatgpt_plan" {
			var kind struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(raw, &kind)
			if kind.Type == "code_interpreter_call" || kind.Type == "image_generation_call" {
				return errors.New("tool_unavailable_for_chatgpt_plan")
			}
		}
		if call != nil {
			if seen[call.CallID] {
				return errors.New("duplicate_local_tool_call_id")
			}
			seen[call.CallID] = true
			pending[call.CallID] = true
		}
		if result != "" {
			if !pending[result] {
				return errors.New("unmatched_local_tool_output")
			}
			delete(pending, result)
		}
	}
	if len(pending) != 0 {
		return errors.New("missing_local_tool_output")
	}
	return nil
}

// Reject duplicate object keys and excessive nesting instead of relying on
// encoding/json's last-key-wins behavior at a tool-execution boundary.
func validateUniqueJSON(raw []byte) error {
	return validateJSONBoundary(raw, nil)
}

func validateJSONBoundary(raw []byte, forbiddenRootKeys map[string]bool) error {
	if !utf8.Valid(raw) {
		return errors.New("invalid_json_utf8")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var read func(int) error
	read = func(depth int) error {
		if depth > 64 {
			return errors.New("json_too_deep")
		}
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return errors.New("duplicate_json_key")
				}
				if depth == 0 && forbiddenRootKeys[name] {
					return errors.New("reserved_json_field")
				}
				seen[name] = true
				if err := read(depth + 1); err != nil {
					return err
				}
			}
			end, err := decoder.Token()
			if err != nil || end != json.Delim('}') {
				return errors.New("invalid_json_object")
			}
		case '[':
			for decoder.More() {
				if err := read(depth + 1); err != nil {
					return err
				}
			}
			end, err := decoder.Token()
			if err != nil || end != json.Delim(']') {
				return errors.New("invalid_json_array")
			}
		default:
			return errors.New("invalid_json_delimiter")
		}
		return nil
	}
	if err := read(0); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("invalid_json_trailing_data")
	}
	return nil
}
