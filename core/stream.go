package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Completed image-generation items contain base64 image bytes in a single SSE
// line. Keep this bounded independently of the smaller text-output limit.
const maxEventBytes = 64 * 1024 * 1024
const maxTextBytes = 32 * 1024 * 1024

type streamEvent struct {
	Type      string `json:"type"`
	Text      string `json:"text,omitempty"`
	Status    string `json:"status,omitempty"`
	ItemID    string `json:"item_id,omitempty"`
	Completed bool   `json:"completed,omitempty"`
}

type streamResult struct {
	Text          string              `json:"text"`
	ResponseID    string              `json:"response_id"`
	Output        json.RawMessage     `json:"output,omitempty"`
	Usage         json.RawMessage     `json:"usage,omitempty"`
	Files         []containerFile     `json:"files,omitempty"`
	FunctionCalls []localFunctionCall `json:"function_calls,omitempty"`
}

type containerFile struct {
	Type        string `json:"type"`
	ContainerID string `json:"container_id"`
	FileID      string `json:"file_id"`
	Filename    string `json:"filename"`
}

type providerStreamFailure struct {
	Kind  string `json:"kind"`
	Code  string `json:"code,omitempty"`
	Param string `json:"param,omitempty"`
}

type completedStreamItem struct {
	raw   json.RawMessage
	index int // -1 means the provider did not supply an output index.
	id    string
}

// Stream consumes Responses SSE bytes. A terminal success event is required.
type Stream struct {
	mu         sync.Mutex
	buffer     []byte
	scanOffset int
	eventData  []string
	eventBytes int
	done       bool
	failure    error
	provider   *providerStreamFailure
	result     streamResult
	localTools *localToolPolicy
	items      []completedStreamItem
	itemBytes  int
	itemError  error
}

func NewStream() *Stream { return &Stream{} }

// Push returns a JSON array of platform-neutral UI events.
func (s *Stream) Push(chunk []byte) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failure != nil {
		return "", s.failure
	}
	if len(s.buffer)+len(chunk) > maxEventBytes {
		return "", s.fail("event_too_large")
	}
	s.buffer = append(s.buffer, chunk...)
	events := []streamEvent{}
	for {
		end := bytes.IndexByte(s.buffer[s.scanOffset:], '\n')
		if end < 0 {
			s.scanOffset = len(s.buffer)
			break
		}
		end += s.scanOffset
		line := strings.TrimSuffix(string(s.buffer[:end]), "\r")
		s.buffer = s.buffer[end+1:]
		s.scanOffset = 0
		if line == "" {
			event, err := s.dispatch()
			if err != nil {
				return "", err
			}
			if event != nil {
				events = append(events, *event)
			}
			continue
		}
		if strings.HasPrefix(line, "data:") {
			value := strings.TrimPrefix(line[5:], " ")
			s.eventBytes += len(value)
			if s.eventBytes > maxEventBytes {
				return "", s.fail("event_too_large")
			}
			s.eventData = append(s.eventData, value)
		}
	}
	data, err := json.Marshal(events)
	return string(data), err
}

func (s *Stream) dispatch() (*streamEvent, error) {
	if len(s.eventData) == 0 {
		return nil, nil
	}
	data := strings.Join(s.eventData, "\n")
	s.eventData = nil
	s.eventBytes = 0
	if data == "[DONE]" {
		if !s.done {
			return nil, s.fail("stream_ended_without_completion")
		}
		return nil, nil
	}
	var event struct {
		Type        string          `json:"type"`
		Delta       string          `json:"delta"`
		ItemID      string          `json:"item_id"`
		OutputIndex *int            `json:"output_index"`
		Item        json.RawMessage `json:"item"`
		Code        json.RawMessage `json:"code"`
		Param       json.RawMessage `json:"param"`
		Error       json.RawMessage `json:"error"`
		Response    struct {
			ID                string          `json:"id"`
			Status            string          `json:"status"`
			Output            json.RawMessage `json:"output"`
			Usage             json.RawMessage `json:"usage"`
			Error             json.RawMessage `json:"error"`
			IncompleteDetails json.RawMessage `json:"incomplete_details"`
		} `json:"response"`
	}
	if err := json.Unmarshal([]byte(data), &event); err != nil {
		return nil, s.fail("invalid_stream_event")
	}
	if event.Type == "response.failed" || event.Type == "error" {
		failure := providerStreamFailure{Kind: event.Type, Code: failureField(event.Code), Param: failureField(event.Param)}
		for _, raw := range []json.RawMessage{event.Response.Error, event.Error} {
			var details struct {
				Code  json.RawMessage `json:"code"`
				Param json.RawMessage `json:"param"`
			}
			if json.Unmarshal(raw, &details) == nil {
				if code := failureField(details.Code); code != "" {
					failure.Code = code
				}
				if param := failureField(details.Param); param != "" {
					failure.Param = param
				}
			}
		}
		s.provider = &failure
		return nil, s.fail("provider_response_failed")
	}
	if event.Type == "response.incomplete" || event.Type == "response.cancelled" {
		var details struct {
			Reason json.RawMessage `json:"reason"`
		}
		_ = json.Unmarshal(event.Response.IncompleteDetails, &details)
		s.provider = &providerStreamFailure{Kind: event.Type, Code: failureField(details.Reason)}
		return nil, s.fail("provider_response_incomplete")
	}
	if s.done {
		return nil, s.fail("event_after_completion")
	}
	switch event.Type {
	case "response.output_item.done":
		if s.itemError == nil {
			if validateUniqueJSON([]byte(data)) != nil {
				s.itemError = errors.New("invalid_response_output")
			} else {
				s.itemError = s.rememberCompletedItem(event.Item, event.OutputIndex)
			}
		}
		// This is only a candidate for the successful terminal boundary. Never
		// publish calls, replay output or a completion event from item.done.
		return nil, nil
	case "response.web_search_call.in_progress", "response.web_search_call.searching", "response.web_search_call.completed",
		"response.code_interpreter_call.in_progress", "response.code_interpreter_call.interpreting", "response.code_interpreter_call.completed",
		"response.image_generation_call.in_progress", "response.image_generation_call.generating", "response.image_generation_call.completed":
		tool := "web_search"
		if strings.HasPrefix(event.Type, "response.code_interpreter_call.") {
			tool = "code_interpreter"
		} else if strings.HasPrefix(event.Type, "response.image_generation_call.") {
			tool = "image_generation"
		}
		id := event.ItemID
		if len(id) == 0 || len(id) > 128 {
			id = ""
			if event.OutputIndex != nil {
				id = strconv.Itoa(*event.OutputIndex)
			}
		}
		return &streamEvent{Type: "status", Status: tool, ItemID: id, Completed: strings.HasSuffix(event.Type, ".completed")}, nil
	case "response.output_text.delta", "response.refusal.delta":
		if len(s.result.Text)+len(event.Delta) > maxTextBytes {
			return nil, s.fail("response_too_large")
		}
		s.result.Text += event.Delta
		return &streamEvent{Type: "delta", Text: event.Delta}, nil
	case "response.completed":
		if (s.localTools != nil || len(s.items) != 0 || s.itemError != nil) && validateUniqueJSON([]byte(data)) != nil {
			return nil, s.fail("invalid_response_output")
		}
		if event.Response.Status != "completed" {
			s.provider = &providerStreamFailure{Kind: "response.incomplete"}
			return nil, s.fail("provider_response_incomplete")
		}
		var rawItems []json.RawMessage
		if len(event.Response.Output) != 0 && string(event.Response.Output) != "null" {
			if err := json.Unmarshal(event.Response.Output, &rawItems); err != nil {
				return nil, s.fail("invalid_response_output")
			}
		}
		output, err := s.outputForCompletion(event.Response.Output, rawItems)
		if err != nil {
			return nil, s.fail(err.Error())
		}
		var items []struct {
			Type    string `json:"type"`
			Content []struct {
				Type        string            `json:"type"`
				Text        string            `json:"text"`
				Refusal     string            `json:"refusal"`
				Annotations []json.RawMessage `json:"annotations"`
			} `json:"content"`
		}
		if len(output) != 0 && string(output) != "null" {
			if err := json.Unmarshal(output, &items); err != nil {
				return nil, s.fail("invalid_response_output")
			}
			if err := json.Unmarshal(output, &rawItems); err != nil {
				return nil, s.fail("invalid_response_output")
			}
		}
		var final strings.Builder
		var calls []localFunctionCall
		seenCalls := map[string]bool{}
		seenCallItems := map[string]bool{}
		for _, raw := range rawItems {
			var kind struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(raw, &kind)
			if s.localTools != nil {
				call, _, err := validateReplayItem(raw, s.localTools, false)
				if err != nil {
					return nil, s.fail(err.Error())
				}
				if call != nil {
					if seenCalls[call.CallID] || (call.ID != "" && seenCallItems[call.ID]) {
						return nil, s.fail("duplicate_local_tool_call_id")
					}
					seenCalls[call.CallID] = true
					if call.ID != "" {
						seenCallItems[call.ID] = true
					}
					calls = append(calls, *call)
					if len(calls) > maxLocalCalls {
						return nil, s.fail("too_many_local_tool_calls")
					}
				}
			} else if !knownHostedOutput(kind.Type) && (strings.HasSuffix(kind.Type, "_call") || strings.HasSuffix(kind.Type, "_call_output") || strings.Contains(kind.Type, "tool")) {
				return nil, s.fail("client_tool_execution_disabled")
			}
		}
		seenFiles := make(map[[2]string]bool)
		for _, item := range items {
			for _, part := range item.Content {
				switch part.Type {
				case "output_text":
					final.WriteString(part.Text)
					if item.Type == "message" {
						for _, annotation := range part.Annotations {
							var file containerFile
							if err := json.Unmarshal(annotation, &file); err != nil ||
								file.Type != "container_file_citation" ||
								!validFileIdentifier(file.ContainerID) || !validFileIdentifier(file.FileID) {
								continue
							}
							identity := [2]string{file.ContainerID, file.FileID}
							if !seenFiles[identity] {
								seenFiles[identity] = true
								s.result.Files = append(s.result.Files, file)
							}
						}
					}
				case "refusal":
					final.WriteString(part.Refusal)
				}
			}
		}
		if final.Len() > maxTextBytes {
			return nil, s.fail("response_too_large")
		}
		if final.Len() != 0 {
			s.result.Text = final.String()
		}
		s.result.ResponseID = event.Response.ID
		s.result.Output = output
		s.result.Usage = event.Response.Usage
		s.result.FunctionCalls = calls
		s.done = true
		s.items = nil
		s.itemBytes = 0
		s.itemError = nil
		return &streamEvent{Type: "completed"}, nil
	default:
		// Provider-owned tool and reasoning events require no client execution.
		return nil, nil
	}
}

func (s *Stream) rememberCompletedItem(raw json.RawMessage, outputIndex *int) error {
	var header struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if json.Unmarshal(raw, &header) != nil || header.Type == "" {
		return errors.New("invalid_response_output")
	}
	index := -1
	if outputIndex != nil {
		index = *outputIndex
		if index < 0 || index >= maxContinuationItems {
			return errors.New("invalid_response_output_index")
		}
	}
	if len(s.items) >= maxContinuationItems || s.itemBytes+len(raw)+1 > maxContinuationBytes-2 {
		return errors.New("continuation_too_large")
	}
	for _, previous := range s.items {
		if (previous.index < 0) != (index < 0) {
			return errors.New("ambiguous_response_output_indices")
		}
		if (index >= 0 && index == previous.index) || (header.ID != "" && header.ID == previous.id) {
			return errors.New("duplicate_response_output_item")
		}
	}
	s.items = append(s.items, completedStreamItem{raw: raw, index: index, id: header.ID})
	s.itemBytes += len(raw) + 1
	return nil
}

// A nonempty terminal remains the sole authority, preserving its existing
// validation and raw bytes. Never merge calls from two competing sources.
// Otherwise complete done items may supply output only after terminal success.
func (s *Stream) outputForCompletion(terminal json.RawMessage, items []json.RawMessage) (json.RawMessage, error) {
	if len(items) > 0 {
		return terminal, nil
	}
	if s.itemError != nil {
		return nil, s.itemError
	}
	if len(s.items) == 0 {
		return terminal, nil
	}
	if s.items[0].index >= 0 {
		sort.Slice(s.items, func(i, j int) bool { return s.items[i].index < s.items[j].index })
	}
	var output bytes.Buffer
	output.WriteByte('[')
	for i, completed := range s.items {
		if completed.index >= 0 && completed.index != i {
			return nil, errors.New("incomplete_response_output_items")
		}
		if i != 0 {
			output.WriteByte(',')
		}
		output.Write(completed.raw)
	}
	output.WriteByte(']')
	return output.Bytes(), nil
}

func failureField(raw json.RawMessage) string {
	var field string
	if json.Unmarshal(raw, &field) != nil || len(field) > 256 {
		return ""
	}
	return field
}

// FailureDetails exposes structured terminal errors without returning free-form
// provider text. Push and Finish still return their stable parser error codes.
func (s *Stream) FailureDetails() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.provider == nil {
		return ""
	}
	data, _ := json.Marshal(s.provider)
	return string(data)
}

func validFileIdentifier(value string) bool {
	if len(value) == 0 || len(value) > 256 {
		return false
	}
	for _, ch := range value {
		switch {
		case ch >= 'A' && ch <= 'Z', ch >= 'a' && ch <= 'z', ch >= '0' && ch <= '9', ch == '_', ch == '-':
		default:
			return false
		}
	}
	return true
}

func (s *Stream) fail(code string) error {
	s.failure = errors.New(code)
	return s.failure
}

// requireCompletedLocked is shared by result readers; the caller holds s.mu.
func (s *Stream) requireCompletedLocked() error {
	if s.failure != nil {
		return s.failure
	}
	if len(bytes.TrimSpace(s.buffer)) != 0 || len(s.eventData) != 0 {
		return s.fail("truncated_stream_event")
	}
	if !s.done {
		return s.fail("stream_ended_without_completion")
	}
	return nil
}

// CompletedOutput returns the terminal output, or complete streamed items after
// a successful terminal with no output items, without platform reconstruction.
// It requires the same complete, successful SSE boundary as Finish.
func (s *Stream) CompletedOutput() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.requireCompletedLocked(); err != nil {
		return "", err
	}
	if len(s.result.Output) == 0 || bytes.Equal(bytes.TrimSpace(s.result.Output), []byte("null")) {
		return "[]", nil
	}
	return string(s.result.Output), nil
}

// Finish rejects interrupted streams, even if some text was received.
func (s *Stream) Finish() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.requireCompletedLocked(); err != nil {
		return "", err
	}
	data, err := json.Marshal(s.result)
	return string(data), err
}
