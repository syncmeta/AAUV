package aauvcore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestImageGenerationPlanAndSubscriptionExclusion(t *testing.T) {
	input := `{"base_url":"https://api.openai.com/v1","model":"fixture","messages":[{"role":"user","content":"Draw"}],"hosted_tools":["image_generation"]}`
	plan, err := BuildRequest(input)
	if err != nil || !strings.Contains(plan, `"output_format":"png"`) || !strings.Contains(plan, `"type":"image_generation"`) {
		t.Fatalf("image generation plan: %s, %v", plan, err)
	}
	for _, invalid := range []string{
		strings.TrimSuffix(input, "}") + `,"credential_kind":"chatgpt_plan"}`,
		strings.TrimSuffix(input, "}") + `,"protocol":"chat_completions"}`,
	} {
		if _, err := BuildRequest(invalid); err == nil {
			t.Fatal("image generation accepted on an unsupported route")
		}
	}
}

func TestImageOnlyResponseKeepsImageBytesAndProgress(t *testing.T) {
	stream := NewStream()
	for _, stage := range []string{"in_progress", "generating", "completed"} {
		input := "data: {\"type\":\"response.image_generation_call." + stage + "\",\"item_id\":\"ig_one\"}\n\n"
		events, err := stream.Push([]byte(input))
		if err != nil || !strings.Contains(events, `"status":"image_generation"`) ||
			(strings.Contains(events, `"completed":true`) != (stage == "completed")) {
			t.Fatalf("image progress: %s, %v", events, err)
		}
	}
	const output = `[{"type":"image_generation_call","status":"completed","output_format":"png","result":"iVBORw0KGgo="}]`
	if _, err := stream.Push([]byte("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":" + output + "}}\n\n")); err != nil {
		t.Fatal(err)
	}
	result, err := stream.Finish()
	var decoded streamResult
	if err != nil || json.Unmarshal([]byte(result), &decoded) != nil || decoded.Text != "" || string(decoded.Output) != output {
		t.Fatalf("image-only result: %s, %v", result, err)
	}
}

func TestImageResultLargerThanOldEventLimit(t *testing.T) {
	// Image bytes are one large SSE line. Scan each newly appended fragment once,
	// keeping a bounded event without the old 8 MiB truncation.
	image := strings.Repeat("A", 9*1024*1024)
	input := []byte("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"image_generation_call\",\"result\":\"" + image + "\"}]}}\r\n\r\n")
	stream := NewStream()
	for len(input) != 0 {
		count := min(len(input), 8192)
		if _, err := stream.Push(input[:count]); err != nil {
			t.Fatal(err)
		}
		input = input[count:]
	}
	result, err := stream.Finish()
	if err != nil || !strings.Contains(result, image) {
		t.Fatal("large image event did not survive completion", err)
	}
}
