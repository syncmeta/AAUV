package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"
)

func imageFinalRequest(model string) request {
	r := fixtureRequest()
	r.Model = model
	r.LocalTools, _ = json.Marshal([]localToolSpec{{Name: "send_images", Description: "synthetic image",
		Parameters: map[string]any{"type": "object", "properties": map[string]any{"images": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}}, "required": []string{"images"}, "additionalProperties": false}}})
	return r
}

func TestImageOnlyFinalRejectsInvalidCompletion(t *testing.T) {
	fixture, _ := filepath.Abs("../Tests/copilot-image-final-runtime-fixture.py")
	legacy := request{Token: "gho_synthetic", Model: "ordinary-empty", Messages: []message{{Role: "user", Content: "normal"}}}
	if _, err := runFixture(t, legacy, fixture, nil); err == nil {
		t.Fatal("zero-tool ordinary empty reply returned success")
	}
	for _, model := range []string{"ordinary-empty", "image-eof", "image-cancelled", "image-no-message"} {
		t.Run(model, func(t *testing.T) {
			_, err := runFixture(t, imageFinalRequest(model), fixture, func(e event) map[string]any {
				return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": e.CallID,
					"status": "ok", "text": `{"ok":true,"sent":1}`}
			})
			if err == nil {
				t.Fatal("empty or interrupted SDK reply became success")
			}
		})
	}
	for _, text := range []string{`{"sent":0}`, `{"sent":6}`, `{"sent":"1"}`, `{"sent":1.5}`} {
		t.Run(text, func(t *testing.T) {
			_, err := runFixture(t, imageFinalRequest("image-only"), fixture, func(e event) map[string]any {
				return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": e.CallID,
					"status": "ok", "text": text}
			})
			if err == nil {
				t.Fatal("invalid image count authorized empty completion")
			}
		})
	}
	r := imageFinalRequest("image-only")
	r.LocalTools, _ = json.Marshal([]localToolSpec{{Name: "search_chat_history", Description: "synthetic",
		Parameters: map[string]any{"type": "object", "properties": map[string]any{"probe": map[string]any{"type": "boolean"}}}}})
	_, err := runFixture(t, r, fixture, func(e event) map[string]any {
		return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": e.CallID,
			"status": "ok", "text": `{"sent":1}`}
	})
	if err == nil {
		t.Fatal("a non-image tool authorized empty completion")
	}
}

func TestImageOnlyCompletedWireHasExplicitText(t *testing.T) {
	data, err := json.Marshal(event{Type: "completed"})
	if err != nil || !bytes.Contains(data, []byte(`"text":""`)) {
		t.Fatal("successful empty completion omitted its text field")
	}
	data, _ = json.Marshal(event{Type: "ready"})
	if bytes.Contains(data, []byte(`"text"`)) {
		t.Fatal("unrelated bridge event shape changed")
	}
}

func TestImageOnlyFinalSDK(t *testing.T) {
	fixture, _ := filepath.Abs("../Tests/copilot-image-final-runtime-fixture.py")
	items, err := runFixture(t, imageFinalRequest("image-only"), fixture, func(e event) map[string]any {
		return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": e.CallID,
			"status": "ok", "text": `{"ok":true,"sent":1}`}
	})
	if err != nil {
		t.Fatalf("prepared image + successful empty final must complete: %v", err)
	}
	if len(items) == 0 || items[len(items)-1].Type != "completed" || items[len(items)-1].Text != "" {
		t.Fatal("missing explicit successful image-only completion")
	}
}
