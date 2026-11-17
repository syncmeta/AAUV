package aauvcore

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestRuntimePromptIdentityAndOriginalDates(t *testing.T) {
	now := float64(time.Date(2026, 11, 5, 18, 0, 0, 0, time.UTC).Unix())
	sent := now - 1800
	input := runtimePromptInput{BotName: "大绿豆", TimeZone: "Asia/Taipei", OffsetSeconds: 28800, Now: now,
		Messages: []runtimePromptMessage{{ID: "user", Role: "user", Content: "今天", Time: &sent, Original: true},
			{ID: "assistant", Role: "assistant", Content: "原回答", Time: &sent, Original: true},
			{ID: "memory", Role: "user", Content: "压缩资料", Time: &now},
			{ID: "unknown", Role: "user", Content: "旧消息", Original: true}}}
	raw, _ := json.Marshal(input)
	encoded, err := RenderRuntimeContext(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	var output runtimePromptOutput
	if err := json.Unmarshal([]byte(encoded), &output); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.Instructions, "你叫「大绿豆」") || !strings.Contains(output.Instructions, "2026年11月6日 02:00:00") || !strings.Contains(output.Instructions, "UTC+08:00") {
		t.Fatal(output.Instructions)
	}
	if !strings.Contains(output.Messages[0].Content, "2026年11月6日 01:30:00") || !strings.Contains(output.Messages[0].Content, "此提示用户不可见") {
		t.Fatal(output.Messages[0])
	}
	for index := 1; index < len(input.Messages); index++ {
		if output.Messages[index].Content != input.Messages[index].Content {
			t.Fatalf("altered non-original/assistant/unknown date at %d", index)
		}
	}
	if input.Messages[0].Content != "今天" || output.Messages[0].ID != "user" || *output.Messages[0].Time != sent {
		t.Fatal("mutated source or identity")
	}
}

func TestRuntimePromptDSTAndFixedOffset(t *testing.T) {
	first := float64(time.Date(2026, 11, 1, 5, 30, 0, 0, time.UTC).Unix())
	second := first + 3600
	request := runtimePromptInput{TimeZone: "America/New_York", OffsetSeconds: -18000, Now: second,
		Messages: []runtimePromptMessage{{Role: "user", Content: "a", Time: &first, Original: true}, {Role: "user", Content: "b", Time: &second, Original: true}}}
	raw, _ := json.Marshal(request)
	encoded, err := RenderRuntimeContext(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	var result runtimePromptOutput
	if json.Unmarshal([]byte(encoded), &result) != nil {
		t.Fatal("decode")
	}
	if !strings.Contains(result.Messages[0].Content, "01:30:00（America/New_York，UTC-04:00）") || !strings.Contains(result.Messages[1].Content, "01:30:00（America/New_York，UTC-05:00）") {
		t.Fatal(encoded)
	}
	request.TimeZone = "GMT+0530"
	request.OffsetSeconds = 19800
	raw, _ = json.Marshal(request)
	encoded, err = RenderRuntimeContext(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(encoded, "UTC+05:30") {
		t.Fatal(encoded)
	}
}

func TestRuntimePromptRejectsInvalidEnvelope(t *testing.T) {
	for _, raw := range []string{`null`, `{"now":1e200}`, `{"now":0,"offsetSeconds":86401}`, `{"now":0,"messages":[{"role":"system"}]}`} {
		_, err := RenderRuntimeContext(raw)
		if err == nil {
			t.Fatal("accepted invalid envelope", raw)
		}
	}
}
