package aauvcore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestResponsesPlanAndHostedExecution(t *testing.T) {
	input := `{"base_url":"https://example.com/v1","model":"test","messages":[{"role":"user","content":"hello"}],"hosted_tools":["code_interpreter"]}`
	plan, err := BuildRequest(input)
	if err != nil {
		t.Fatal(err)
	}
	var decoded requestPlan
	if err := json.Unmarshal([]byte(plan), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.URL != "https://example.com/v1/responses" || !decoded.Streaming {
		t.Fatal(plan)
	}
	var body map[string]any
	if err := json.Unmarshal(decoded.Body, &body); err != nil {
		t.Fatal(err)
	}
	if body["store"] != false || body["stream"] != true {
		t.Fatal(body)
	}
	tools := body["tools"].([]any)
	if tools[0].(map[string]any)["container"].(map[string]any)["type"] != "auto" {
		t.Fatal(body)
	}
	planOnly := strings.TrimSuffix(input, "}") + `,"credential_kind":"chatgpt_plan"}`
	if _, err := BuildRequest(planOnly); err == nil {
		t.Fatal("unsupported plan tool accepted")
	}
	localTool := strings.Replace(input, "code_interpreter", "execute_code", 1)
	if _, err := BuildRequest(localTool); err == nil {
		t.Fatal("local execution accepted")
	}
}

func TestUploadedResponsesAttachments(t *testing.T) {
	const input = `{"base_url":"https://api.openai.com/v1","model":"test","credential_kind":"byok","protocol":"responses",
		"messages":[{"role":"user","content":"Inspect"}],
		"files":[{"name":"data.bin","media_type":"application/octet-stream","file_id":"file-data"},
			{"name":"image.png","media_type":"image/png","file_id":"file-image"}]}`
	plan, err := BuildRequest(input)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		`{"file_id":"file-data","type":"input_file"}`,
		`{"detail":"auto","file_id":"file-image","type":"input_image"}`,
	} {
		if !strings.Contains(plan, expected) {
			t.Fatalf("missing %s in %s", expected, plan)
		}
	}
	for _, invalid := range []string{
		strings.Replace(input, `"byok"`, `"chatgpt_plan"`, 1),
		strings.Replace(input, `"responses"`, `"chat_completions"`, 1),
		strings.Replace(input, `"file-data"`, `"../other"`, 1),
		strings.Replace(input, `"file_id":"file-data"`, `"file_id":"file-data","data":"AA=="`, 1),
	} {
		if _, err := BuildRequest(invalid); err == nil {
			t.Fatal("unexpected acceptance of invalid file reference")
		}
	}
}

func TestStreamingBoundariesAndTerminalState(t *testing.T) {
	stream := NewStream()
	events := "data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\r\n\r\n" +
		"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"output\":[]}}\n\n"
	for _, b := range []byte(events) {
		if _, err := stream.Push([]byte{b}); err != nil {
			t.Fatal(err)
		}
	}
	final, err := stream.Finish()
	if err != nil {
		t.Fatal(err)
	}
	var result streamResult
	json.Unmarshal([]byte(final), &result)
	if result.Text != "你好" || result.ResponseID != "r1" {
		t.Fatal(final)
	}
	incomplete := NewStream()
	incomplete.Push([]byte("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"))
	if _, err := incomplete.Finish(); err == nil {
		t.Fatal("partial stream accepted")
	}
}

func TestFailuresAndClientTools(t *testing.T) {
	for _, input := range []string{
		`{"type":"response.failed"}`,
		`{"type":"response.incomplete"}`,
		`{"type":"response.completed","response":{"status":"failed"}}`,
		`{"type":"response.completed","response":{"status":"completed","output":[{"type":"function_call"}]}}`,
	} {
		stream := NewStream()
		if _, err := stream.Push([]byte("data: " + input + "\n\n")); err == nil {
			t.Fatal(input)
		}
		if _, err := stream.Finish(); err == nil {
			t.Fatal("failure forgotten")
		}
	}
}

func TestStreamPreservesStructuredFailureWithoutProviderText(t *testing.T) {
	for _, test := range []struct {
		event string
		code  string
		param string
	}{
		{`{"type":"error","code":"failure","param":"input","message":"private text"}`, "failure", "input"},
		{`{"type":"response.failed","response":{"error":{"code":"limit","param":null,"message":"private text"}}}`, "limit", ""},
		{`{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}`, "max_output_tokens", ""},
	} {
		stream := NewStream()
		if _, err := stream.Push([]byte("data: " + test.event + "\n\n")); err == nil {
			t.Fatal("terminal failure was accepted")
		}
		if _, err := stream.Finish(); err == nil {
			t.Fatal("terminal failure appeared complete")
		}
		raw := stream.FailureDetails()
		var detail providerStreamFailure
		if json.Unmarshal([]byte(raw), &detail) != nil || detail.Code != test.code || detail.Param != test.param ||
			strings.Contains(raw, "private text") {
			t.Fatal("unexpected provider diagnostic", raw)
		}
	}
}

func TestStreamCollectsOnlyUniqueSafeContainerFiles(t *testing.T) {
	stream := NewStream()
	event := `{"type":"response.completed","response":{"status":"completed","output":[
		{"type":"message","content":[{"type":"output_text","text":"Result","annotations":[
			{"type":"container_file_citation","container_id":"cntr_1","file_id":"cfile_2","filename":"plot.png"},
			{"type":"container_file_citation","container_id":"cntr_1","file_id":"cfile_2","filename":"duplicate.png"},
			{"type":"container_file_citation","container_id":"cntr_1","file_id":"../metadata","filename":"unsafe"},
			{"type":"url_citation","url":"https://example.invalid/"},
			{"type":"container_file_citation","container_id":123,"file_id":"wrong_type"}
		]}]}
	]}}`
	lines := strings.Split(event, "\n")
	if _, err := stream.Push([]byte("data: " + strings.Join(lines, "\ndata: ") + "\n\n")); err != nil {
		t.Fatal(err)
	}
	final, err := stream.Finish()
	if err != nil {
		t.Fatal(err)
	}
	var result streamResult
	if err := json.Unmarshal([]byte(final), &result); err != nil {
		t.Fatal(err)
	}
	if result.Text != "Result" || len(result.Files) != 1 || result.Files[0].Filename != "plot.png" {
		t.Fatal(final)
	}
}

func TestLegacyAndReservedProtocols(t *testing.T) {
	base := `{"protocol":"chat_completions","base_url":"https://example.com/v1","model":"test","messages":[{"role":"user","content":"hello"}]}`
	plan, err := BuildRequest(base)
	if err != nil || !strings.Contains(plan, "/chat/completions") {
		t.Fatalf("%s %v", plan, err)
	}
	if _, err := BuildRequest(strings.Replace(base, "chat_completions", "anthropic_messages", 1)); err == nil {
		t.Fatal("reserved protocol silently accepted")
	}
	_, err = DecodeCompletion(`{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}`)
	if err == nil {
		t.Fatal("truncated completion accepted")
	}
}
