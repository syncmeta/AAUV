// Package aauvcore contains shared mobile application logic.
// Platform adapters own credentials, HTTP transport, UI, and OS permissions.
package aauvcore

import (
	"encoding/json"
	"errors"
	"net/url"
	"strings"
)

const (
	responses           = "responses"
	chatCompletions     = "chat_completions"
	anthropicMessages   = "anthropic_messages"
	maxRequestBytes     = 16 * 1024 * 1024
	maxToolRequestBytes = 64 * 1024 * 1024
)

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type inputFile struct {
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	Data      string `json:"data"`
	FileID    string `json:"file_id"`
}

type wireMessage struct {
	Role    string `json:"role"`
	Content any    `json:"content"`
}

type requestConfig struct {
	Protocol       string            `json:"protocol"`
	BaseURL        string            `json:"base_url"`
	Model          string            `json:"model"`
	Messages       []message         `json:"messages"`
	Instructions   string            `json:"instructions,omitempty"`
	HostedTools    []string          `json:"hosted_tools,omitempty"`
	Files          []inputFile       `json:"files,omitempty"`
	CredentialKind string            `json:"credential_kind,omitempty"`
	LocalTools     []string          `json:"local_tools,omitempty"`
	Continuation   []json.RawMessage `json:"continuation,omitempty"`
}

type requestPlan struct {
	URL       string          `json:"url"`
	Body      json.RawMessage `json:"body"`
	Streaming bool            `json:"streaming"`
}

// BuildRequest returns a credential-free HTTP request plan.
// Authentication headers are applied by the platform's secure credential adapter.
func BuildRequest(input string) (string, error) {
	if len(input) > maxToolRequestBytes {
		return "", errors.New("request_too_large")
	}
	var config requestConfig
	if err := json.Unmarshal([]byte(input), &config); err != nil {
		return "", errors.New("invalid_request")
	}
	localToolRequest := len(config.LocalTools) != 0 || len(config.Continuation) != 0
	if len(input) > maxRequestBytes && !localToolRequest {
		return "", errors.New("request_too_large")
	}
	if config.Protocol == "" {
		config.Protocol = responses
	}
	if localToolRequest {
		if config.Protocol != responses {
			return "", errors.New("local_tools_require_responses")
		}
		forbidden := map[string]bool{}
		for _, key := range []string{"tools", "input", "additional_tools", "previous_response_id", "store", "stream", "tool_choice"} {
			forbidden[key] = true
		}
		if validateJSONBoundary([]byte(input), forbidden) != nil {
			return "", errors.New("invalid_request")
		}
	}
	if strings.TrimSpace(config.Model) == "" {
		return "", errors.New("model_required")
	}
	if len(config.Messages) == 0 {
		return "", errors.New("messages_required")
	}
	for _, item := range config.Messages {
		if item.Role != "user" && item.Role != "assistant" {
			return "", errors.New("unsupported_message_role")
		}
	}
	base, err := url.Parse(strings.TrimRight(config.BaseURL, "/"))
	if err != nil || base.Hostname() == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return "", errors.New("invalid_base_url")
	}
	local := base.Hostname() == "localhost" || base.Hostname() == "127.0.0.1" || base.Hostname() == "::1"
	if base.Scheme != "https" && !(base.Scheme == "http" && local) {
		return "", errors.New("https_required")
	}
	if config.CredentialKind == "chatgpt_plan" &&
		(config.Protocol != responses || base.String() != "https://api.openai.com/v1") {
		return "", errors.New("chatgpt_plan_requires_official_responses_endpoint")
	}
	messages, err := formatMessages(config)
	if err != nil {
		return "", err
	}
	var payload any
	var suffix string
	switch config.Protocol {
	case responses:
		suffix = "/responses"
		namespace := ""
		if config.CredentialKind == "chatgpt_plan" {
			namespace = localToolNamespace
		}
		policy, err := newLocalToolPolicy(config.LocalTools, namespace)
		if err != nil {
			return "", err
		}
		if err := validateContinuation(config.Continuation, policy, config.CredentialKind); err != nil {
			return "", err
		}
		tools := make([]map[string]any, 0, len(config.HostedTools))
		seen := map[string]bool{}
		for _, tool := range config.HostedTools {
			if seen[tool] {
				return "", errors.New("duplicate_hosted_tool")
			}
			seen[tool] = true
			switch tool {
			case "web_search":
				tools = append(tools, map[string]any{"type": tool})
			case "code_interpreter":
				if config.CredentialKind == "chatgpt_plan" {
					return "", errors.New("tool_unavailable_for_chatgpt_plan")
				}
				tools = append(tools, map[string]any{"type": tool, "container": map[string]string{"type": "auto"}})
			case "image_generation":
				if config.CredentialKind == "chatgpt_plan" {
					return "", errors.New("tool_unavailable_for_chatgpt_plan")
				}
				tools = append(tools, map[string]any{"type": tool, "output_format": "png"})
			default:
				return "", errors.New("unsupported_hosted_tool")
			}
		}
		tools = append(tools, policy.definitions()...)
		inputItems := make([]json.RawMessage, 0, len(messages)+len(config.Continuation))
		for _, item := range messages {
			encoded, err := json.Marshal(item)
			if err != nil {
				return "", errors.New("request_encoding_failed")
			}
			inputItems = append(inputItems, encoded)
		}
		inputItems = append(inputItems, config.Continuation...)
		var include []string
		if len(config.LocalTools) != 0 {
			include = []string{"reasoning.encrypted_content"}
		}
		payload = struct {
			Model        string            `json:"model"`
			Input        []json.RawMessage `json:"input"`
			Instructions string            `json:"instructions,omitempty"`
			Stream       bool              `json:"stream"`
			Store        bool              `json:"store"`
			Tools        []map[string]any  `json:"tools,omitempty"`
			Include      []string          `json:"include,omitempty"`
		}{config.Model, inputItems, config.Instructions, true, false, tools, include}
	case chatCompletions:
		if len(config.HostedTools) != 0 {
			return "", errors.New("hosted_tools_require_responses")
		}
		suffix = "/chat/completions"
		if config.Instructions != "" {
			messages = append([]wireMessage{{Role: "system", Content: config.Instructions}}, messages...)
		}
		payload = struct {
			Model    string        `json:"model"`
			Messages []wireMessage `json:"messages"`
		}{config.Model, messages}
	case anthropicMessages:
		return "", errors.New("anthropic_messages_not_implemented")
	default:
		return "", errors.New("unsupported_protocol")
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", errors.New("request_encoding_failed")
	}
	if localToolRequest && len(body) > maxToolRequestBytes {
		return "", errors.New("request_too_large")
	}
	base.Path += suffix
	base.RawPath = ""
	encoded, err := json.Marshal(requestPlan{base.String(), body, config.Protocol == responses})
	return string(encoded), err
}

func formatMessages(config requestConfig) ([]wireMessage, error) {
	messages := make([]wireMessage, 0, len(config.Messages))
	for _, m := range config.Messages {
		messages = append(messages, wireMessage{m.Role, m.Content})
	}
	if len(config.Files) == 0 {
		return messages, nil
	}
	last := &messages[len(messages)-1]
	if last.Role != "user" {
		return nil, errors.New("attachments_require_user_message")
	}
	textType := "input_text"
	if config.Protocol == chatCompletions {
		textType = "text"
	}
	parts := []map[string]any{{"type": textType, "text": last.Content}}
	for _, file := range config.Files {
		if file.Name == "" || file.MediaType == "" {
			return nil, errors.New("invalid_attachment")
		}
		if file.FileID != "" {
			if config.Protocol != responses || config.CredentialKind == "chatgpt_plan" ||
				file.Data != "" || !validFileIdentifier(file.FileID) {
				return nil, errors.New("invalid_uploaded_attachment")
			}
			switch file.MediaType {
			case "image/png", "image/jpeg", "image/gif", "image/webp":
				parts = append(parts, map[string]any{"type": "input_image", "file_id": file.FileID, "detail": "auto"})
			default:
				parts = append(parts, map[string]any{"type": "input_file", "file_id": file.FileID})
			}
			continue
		}
		dataURL := "data:" + file.MediaType + ";base64," + file.Data
		switch file.MediaType {
		case "image/png", "image/jpeg", "image/gif", "image/webp":
			if config.Protocol == chatCompletions {
				parts = append(parts, map[string]any{"type": "image_url", "image_url": map[string]string{"url": dataURL}})
			} else {
				parts = append(parts, map[string]any{"type": "input_image", "image_url": dataURL})
			}
		default:
			if config.Protocol == chatCompletions {
				parts = append(parts, map[string]any{"type": "file", "file": map[string]string{"filename": file.Name, "file_data": dataURL}})
			} else {
				parts = append(parts, map[string]any{"type": "input_file", "filename": file.Name, "file_data": dataURL})
			}
		}
	}
	last.Content = parts
	return messages, nil
}

// DecodeCompletion preserves support for existing Chat Completions profiles.
func DecodeCompletion(input string) (string, error) {
	var payload struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content   string            `json:"content"`
				Refusal   string            `json:"refusal"`
				ToolCalls []json.RawMessage `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(input), &payload); err != nil {
		return "", errors.New("invalid_completion")
	}
	if len(payload.Choices) == 0 {
		return "", errors.New("empty_completion")
	}
	choice := payload.Choices[0]
	if len(choice.Message.ToolCalls) > 0 {
		return "", errors.New("client_tool_execution_disabled")
	}
	if choice.FinishReason != "" && choice.FinishReason != "stop" {
		return "", errors.New("incomplete_completion")
	}
	text := choice.Message.Content
	if text == "" {
		text = choice.Message.Refusal
	}
	if text == "" {
		return "", errors.New("empty_completion")
	}
	return text, nil
}
