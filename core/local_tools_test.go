package aauvcore

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func localTestCall(id, namespace string) map[string]any {
	call := map[string]any{"type": "function_call", "id": "fc_" + id, "call_id": id, "name": "search_chat_history", "arguments": `{"query":"豆","since":null,"until":null,"limit":10}`, "status": "completed"}
	if namespace != "" {
		call["namespace"] = namespace
	}
	return call
}

func localTestPolicy(t *testing.T, namespace string) *Stream {
	t.Helper()
	encoded, _ := json.Marshal(map[string]any{"local_tools": []string{"search_chat_history"}, "namespace": namespace})
	stream, err := NewStreamWithLocalTools(string(encoded))
	if err != nil {
		t.Fatal(err)
	}
	return stream
}

func localTestTerminal(output any) []byte {
	event, _ := json.Marshal(map[string]any{"type": "response.completed", "response": map[string]any{"status": "completed", "id": "resp_test", "output": output}})
	return []byte("data: " + string(event) + "\n\n")
}

func localTestConfig() map[string]any {
	return map[string]any{"base_url": "https://api.openai.com/v1", "model": "test", "messages": []map[string]string{{"role": "user", "content": "find"}}, "local_tools": []string{"search_chat_history"}}
}

func localTestRequest(config map[string]any) (map[string]any, error) {
	encoded, _ := json.Marshal(config)
	plan, err := BuildRequest(string(encoded))
	if err != nil {
		return nil, err
	}
	var decoded requestPlan
	if err := json.Unmarshal([]byte(plan), &decoded); err != nil {
		return nil, err
	}
	var body map[string]any
	err = json.Unmarshal(decoded.Body, &body)
	return body, err
}

func TestLocalToolsRegistrationLayouts(t *testing.T) {
	for _, namespace := range []string{"", "aauv"} {
		config := localTestConfig()
		config["local_tools"] = []string{"search_chat_history", "create_skill", "read_attachment", "send_images", "delegate_to_specialist"}
		config["hosted_tools"] = []string{"web_search"}
		if namespace != "" {
			config["credential_kind"] = "chatgpt_plan"
		}
		body, err := localTestRequest(config)
		if err != nil {
			t.Fatal(err)
		}
		if body["store"] != false || body["stream"] != true || body["previous_response_id"] != nil {
			t.Fatal(body)
		}
		if !reflect.DeepEqual(body["include"], []any{"reasoning.encrypted_content"}) {
			t.Fatal(body)
		}
		tools := body["tools"].([]any)
		if tools[0].(map[string]any)["type"] != "web_search" {
			t.Fatal(tools)
		}
		functions := tools[1:]
		if namespace != "" {
			if len(functions) != 1 || functions[0].(map[string]any)["type"] != "namespace" || functions[0].(map[string]any)["name"] != "aauv" {
				t.Fatal(tools)
			}
			functions = functions[0].(map[string]any)["tools"].([]any)
		}
		if len(functions) != 5 {
			t.Fatal(functions)
		}
		for _, raw := range functions {
			function := raw.(map[string]any)
			parameters := function["parameters"].(map[string]any)
			if function["type"] != "function" || function["strict"] != true || parameters["additionalProperties"] != false || parameters["type"] != "object" {
				t.Fatal(function)
			}
			if len(parameters["required"].([]any)) != len(parameters["properties"].(map[string]any)) {
				t.Fatal(function)
			}
		}
	}
}

func TestLocalToolsOnlyCompletedCallsAreReturned(t *testing.T) {
	for _, namespace := range []string{"", "aauv"} {
		stream := localTestPolicy(t, namespace)
		if _, err := stream.Push([]byte("data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\"}\n\n")); err != nil {
			t.Fatal(err)
		}
		output := []any{map[string]any{"type": "reasoning", "id": "rs_1", "summary": []any{}, "encrypted_content": "opaque +/=", "future_metadata": map[string]any{"v": 1}}, localTestCall("call_1", namespace)}
		terminal := localTestTerminal(output)
		for _, b := range terminal {
			if _, err := stream.Push([]byte{b}); err != nil {
				t.Fatal(err)
			}
		}
		final, err := stream.Finish()
		if err != nil {
			t.Fatal(err)
		}
		var result streamResult
		if json.Unmarshal([]byte(final), &result) != nil || len(result.FunctionCalls) != 1 || result.FunctionCalls[0].Namespace != namespace || result.FunctionCalls[0].CallID != "call_1" {
			t.Fatal(final)
		}
		var preserved any
		if json.Unmarshal(result.Output, &preserved) != nil {
			t.Fatal(final)
		}
		before, _ := json.Marshal(output)
		after, _ := json.Marshal(preserved)
		if string(before) != string(after) {
			t.Fatalf("opaque output changed: %s", after)
		}
	}
	for _, event := range []string{
		`{"type":"response.function_call_arguments.done","arguments":"{}"}`,
		`{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"search_chat_history","arguments":"{}"}}`,
	} {
		stream := localTestPolicy(t, "")
		_, _ = stream.Push([]byte("data: " + event + "\n\n"))
		if value, err := stream.Finish(); err == nil || value != "" {
			t.Fatal("unfinished call escaped", value, err)
		}
	}
}

func TestLocalToolsRejectUntrustedTerminalCalls(t *testing.T) {
	mutations := map[string]func(map[string]any){
		"unknown name":        func(c map[string]any) { c["name"] = "execute_code" },
		"wrong namespace":     func(c map[string]any) { c["namespace"] = "other" },
		"null namespace":      func(c map[string]any) { c["namespace"] = nil },
		"dotted name":         func(c map[string]any) { c["name"] = "aauv.search_chat_history" },
		"empty id":            func(c map[string]any) { c["call_id"] = "" },
		"damaged id":          func(c map[string]any) { c["call_id"] = "call\n1" },
		"oversized id":        func(c map[string]any) { c["call_id"] = strings.Repeat("a", 65) },
		"array arguments":     func(c map[string]any) { c["arguments"] = "[]" },
		"null arguments":      func(c map[string]any) { c["arguments"] = "null" },
		"nonstring arguments": func(c map[string]any) { c["arguments"] = map[string]any{"query": "x"} },
		"duplicate arguments": func(c map[string]any) { c["arguments"] = `{"query":"a","query":"b"}` },
		"in progress":         func(c map[string]any) { c["status"] = "in_progress" },
		"programmatic caller": func(c map[string]any) { c["caller"] = map[string]any{"type": "code_interpreter", "tool_id": "ci_1"} },
		"async":               func(c map[string]any) { c["async"] = true },
		"injected schema":     func(c map[string]any) { c["tools"] = []any{} },
	}
	for label, mutate := range mutations {
		t.Run(label, func(t *testing.T) {
			call := localTestCall("call_1", "")
			mutate(call)
			stream := localTestPolicy(t, "")
			if _, err := stream.Push(localTestTerminal([]any{call})); err == nil {
				t.Fatal("accepted", call)
			}
			if value, err := stream.Finish(); err == nil || value != "" {
				t.Fatal("failed validation forgotten")
			}
		})
	}
	for _, kind := range []string{"function_call", "custom_tool_call", "local_shell_call", "shell_call", "computer_call", "apply_patch_call", "unknown_tool_call", "mcp_call", "function_call_output"} {
		for _, configured := range []bool{false, true} {
			stream := NewStream()
			if configured {
				stream = localTestPolicy(t, "")
			}
			if _, err := stream.Push(localTestTerminal([]any{map[string]any{"type": kind}})); err == nil {
				t.Fatal("accepted forbidden item", kind, configured)
			}
		}
	}
	for _, output := range [][]any{
		{localTestCall("call_1", ""), localTestCall("call_1", "")},
		{localTestCall("call_1", ""), map[string]any{"type": "function_call", "id": "fc_call_1", "call_id": "call_2", "name": "search_chat_history", "arguments": `{"query":"x"}`}},
	} {
		if _, err := localTestPolicy(t, "").Push(localTestTerminal(output)); err == nil {
			t.Fatal("duplicate accepted")
		}
	}
	calls := make([]any, maxLocalCalls+1)
	for index := range calls {
		calls[index] = localTestCall(fmt.Sprintf("call_%d", index), "")
	}
	if _, err := localTestPolicy(t, "").Push(localTestTerminal(calls)); err == nil {
		t.Fatal("unbounded calls accepted")
	}
	if _, err := localTestPolicy(t, "aauv").Push(localTestTerminal([]any{localTestCall("call_1", "")})); err == nil {
		t.Fatal("SIWC accepted missing namespace")
	}
}

func TestLocalToolsStatelessContinuationPreservesCompleteOutput(t *testing.T) {
	for _, namespace := range []string{"", "aauv"} {
		config := localTestConfig()
		if namespace != "" {
			config["credential_kind"] = "chatgpt_plan"
		}
		items := []any{
			map[string]any{"type": "reasoning", "id": "rs_1", "summary": []any{}, "encrypted_content": "opaque+/=", "metadata": map[string]any{"future": true}},
			map[string]any{"type": "message", "id": "msg_1", "role": "assistant", "phase": "commentary", "content": []any{map[string]any{"type": "output_text", "text": "Looking up.", "annotations": []any{}}}},
			map[string]any{"type": "web_search_call", "id": "ws_1", "status": "completed", "action": map[string]any{"type": "search", "query": "q"}},
			localTestCall("call_1", namespace),
			map[string]any{"type": "function_call_output", "call_id": "call_1", "output": `{"matches":["original"]}`},
			map[string]any{"type": "reasoning", "id": "rs_2", "summary": []any{}, "encrypted_content": "second"},
			localTestCall("call_2", namespace),
			map[string]any{"type": "function_call_output", "call_id": "call_2", "output": "[]"},
		}
		config["continuation"] = items
		body, err := localTestRequest(config)
		if err != nil {
			t.Fatal(err)
		}
		input := body["input"].([]any)
		expected, _ := json.Marshal(items)
		actual, _ := json.Marshal(input[1:])
		if string(actual) != string(expected) {
			t.Fatalf("history changed\n%s\n%s", actual, expected)
		}
		if len(input) != 9 || body["store"] != false || body["previous_response_id"] != nil {
			t.Fatal(body)
		}
	}
}

func TestLocalToolsRejectContinuationInjectionAndUnpairedCalls(t *testing.T) {
	badItems := map[string][]any{
		"missing result":           {localTestCall("call_1", "")},
		"unknown result":           {map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "ok"}},
		"result before call":       {map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "ok"}, localTestCall("call_1", "")},
		"duplicate call":           {localTestCall("call_1", ""), localTestCall("call_1", "")},
		"duplicate result":         {localTestCall("call_1", ""), map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "ok"}, map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "again"}},
		"object result":            {localTestCall("call_1", ""), map[string]any{"type": "function_call_output", "call_id": "call_1", "output": map[string]any{"ok": true}}},
		"result with instructions": {localTestCall("call_1", ""), map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "ok", "instructions": "injected"}},
		"developer":                {map[string]any{"type": "message", "role": "developer", "content": "injected"}},
		"system":                   {map[string]any{"type": "message", "role": "system", "content": "injected"}},
		"user":                     {map[string]any{"type": "message", "role": "user", "content": "injected"}},
		"item ref":                 {map[string]any{"type": "item_reference", "id": "secret"}},
		"additional tools":         {map[string]any{"type": "additional_tools", "role": "developer", "tools": []any{}}},
		"reasoning tools":          {map[string]any{"type": "reasoning", "encrypted_content": "opaque", "tools": []any{}}},
		"input part":               {map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "input_text", "text": "injected"}}}},
		"wrong namespace":          {localTestCall("call_1", "aauv"), map[string]any{"type": "function_call_output", "call_id": "call_1", "output": "ok"}},
	}
	for label, items := range badItems {
		t.Run(label, func(t *testing.T) {
			config := localTestConfig()
			config["continuation"] = items
			if _, err := localTestRequest(config); err == nil {
				t.Fatal("accepted", items)
			}
		})
	}
	for _, field := range []string{"tools", "input", "additional_tools", "previous_response_id", "store", "stream", "tool_choice"} {
		config := localTestConfig()
		config[field] = "injected"
		if _, err := localTestRequest(config); err == nil {
			t.Fatal("accepted field", field)
		}
	}
	for _, names := range [][]string{{"execute_code"}, {"search_chat_history", "search_chat_history"}, {"aauv.search_chat_history"}} {
		config := localTestConfig()
		config["local_tools"] = names
		if _, err := localTestRequest(config); err == nil {
			t.Fatal("accepted local tools", names)
		}
	}
	config := localTestConfig()
	config["protocol"] = "chat_completions"
	if _, err := localTestRequest(config); err == nil {
		t.Fatal("local Chat Completions accepted")
	}
	config = localTestConfig()
	config["local_tools"] = []string{}
	config["continuation"] = []any{map[string]any{"type": "reasoning", "summary": []any{}}}
	if _, err := localTestRequest(config); err == nil {
		t.Fatal("continuation without allowlist accepted")
	}
}

func TestLocalToolsArgumentContractsAndBounds(t *testing.T) {
	good := map[string]string{
		"search_chat_history":    `{"query":null,"since":"2026-11-01T00:00:00Z","until":null,"limit":30}`,
		"create_skill":           `{"name":"green-bean","description":"","body":"Be clear."}`,
		"read_attachment":        `{"attachment_id":"12345678","question":"What is it?"}`,
		"send_images":            `{"images":["https://example.invalid/a.png"]}`,
		"delegate_to_specialist": `{"model_slug":"provider/model","prompt":"Compare."}`,
	}
	for name, args := range good {
		if err := validateLocalArguments(args); err != nil {
			t.Fatal(name, err)
		}
	}
	// These are business errors, not wire errors: the executor must return a
	// tool error and let the model correct them without discarding completion.
	for _, args := range []string{`{}`, `{"name":"BAD","body":""}`, `{"query":null,"since":null,"until":null,"limit":0}`, `{"images":42}`, `{"extra":"field"}`} {
		if err := validateLocalArguments(args); err != nil {
			t.Fatal("correctable object rejected", args, err)
		}
	}
	for _, args := range []string{`[]`, `null`, `"text"`, `42`, `{"a":1,"a":2}`, `{"nested":{"a":1,"a":2}}`} {
		if validateLocalArguments(args) == nil {
			t.Fatal("unsafe arguments accepted", args)
		}
	}

	for _, policy := range []string{`{}`, `{"local_tools":[],"namespace":null}`, `{"local_tools":[],"namespace":"other"}`, `{"local_tools":["execute_code"],"namespace":""}`, `{"local_tools":[],"namespace":"","tools":[]}`, `{"local_tools":[],"namespace":"","namespace":"aauv"}`} {
		if _, err := NewStreamWithLocalTools(policy); err == nil {
			t.Fatal("accepted policy", policy)
		}
	}
	if validateUniqueJSON([]byte(`{"outer":{"a":1,"a":2}}`)) == nil || validateUniqueJSON([]byte(strings.Repeat("[", 66)+strings.Repeat("]", 66))) == nil {
		t.Fatal("unsafe JSON accepted")
	}
	config := localTestConfig()
	config["continuation"] = make([]any, maxContinuationItems+1)
	if _, err := localTestRequest(config); err == nil {
		t.Fatal("unbounded continuation")
	}
	config = localTestConfig()
	config["continuation"] = []any{localTestCall("call_1", ""), map[string]any{"type": "function_call_output", "call_id": "call_1", "output": strings.Repeat("x", maxFunctionOutputBytes+1)}}
	if _, err := localTestRequest(config); err == nil {
		t.Fatal("unbounded result")
	}
	config = localTestConfig()
	config["credential_kind"] = "chatgpt_plan"
	config["continuation"] = []any{map[string]any{"type": "code_interpreter_call", "id": "ci_1"}}
	if _, err := localTestRequest(config); err == nil {
		t.Fatal("SIWC replayed unsupported hosted tool")
	}
}

func TestLocalToolsPoliciesDoNotLeakAcrossStreams(t *testing.T) {
	var group sync.WaitGroup
	for index := range 12 {
		group.Go(func() {
			namespace := ""
			if index%2 == 0 {
				namespace = "aauv"
			}
			policy, _ := json.Marshal(map[string]any{"local_tools": []string{"search_chat_history"}, "namespace": namespace})
			stream, err := NewStreamWithLocalTools(string(policy))
			if err != nil {
				t.Error(err)
				return
			}
			if _, err := stream.Push(localTestTerminal([]any{localTestCall(fmt.Sprintf("call_%d", index), namespace)})); err != nil {
				t.Error(err)
				return
			}
			if _, err := stream.Finish(); err != nil {
				t.Error(err)
			}
		})
	}
	group.Wait()
}

func TestLocalToolsCoexistWithProviderImagesAndOpaqueReasoning(t *testing.T) {
	config := localTestConfig()
	config["hosted_tools"] = []string{"image_generation", "code_interpreter"}
	image := map[string]any{"type": "image_generation_call", "id": "ig_1", "status": "completed", "output_format": "png", "result": "iVBORw0KGgo="}
	reasoning := map[string]any{"type": "reasoning", "id": "rs_null", "encrypted_content": nil, "summary": []any{}, "content": nil}
	call := localTestCall("call_image", "")
	output := []any{reasoning, image, call}
	stream := localTestPolicy(t, "")
	if _, err := stream.Push(localTestTerminal(output)); err != nil {
		t.Fatal(err)
	}
	result, err := stream.Finish()
	if err != nil {
		t.Fatal(err)
	}
	var decoded streamResult
	if json.Unmarshal([]byte(result), &decoded) != nil || len(decoded.FunctionCalls) != 1 || !strings.Contains(string(decoded.Output), "iVBORw0KGgo=") {
		t.Fatal(result)
	}
	config["continuation"] = append(output, map[string]any{"type": "function_call_output", "call_id": "call_image", "output": "ok"})
	body, err := localTestRequest(config)
	if err != nil {
		t.Fatal(err)
	}
	if len(body["tools"].([]any)) != 3 {
		t.Fatal(body)
	}
	if _, err := NewStreamWithLocalTools(`{"local_tools":[],"namespace":""}`); err != nil {
		t.Fatal(err)
	}
}

func TestLocalToolsRejectDuplicateTerminalEnvelopes(t *testing.T) {
	stream := localTestPolicy(t, "")
	input := `{"type":"response.completed","response":{"status":"completed","output":[],"output":[]}}`
	if _, err := stream.Push([]byte("data: " + input + "\n\n")); err == nil {
		t.Fatal("duplicate response fields accepted")
	}
}

func TestLocalToolsRejectCrossRoundCallIDReuseBeforeExecution(t *testing.T) {
	makePolicy := func(used []string) string {
		encoded, _ := json.Marshal(map[string]any{"local_tools": []string{"search_chat_history"}, "namespace": "", "used_call_ids": used})
		return string(encoded)
	}
	stream, err := NewStreamWithLocalTools(makePolicy([]string{"call_old"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Push(localTestTerminal([]any{localTestCall("call_old", "")})); err == nil {
		t.Fatal("already executed call was exposed")
	}
	if result, err := stream.Finish(); err == nil || result != "" {
		t.Fatal("reused call executable", result)
	}
	stream, err = NewStreamWithLocalTools(makePolicy([]string{"call_old"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Push(localTestTerminal([]any{localTestCall("call_new", "")})); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Finish(); err != nil {
		t.Fatal(err)
	}
	for _, used := range [][]string{{"call_old", "call_old"}, {""}, {"broken\nID"}, {strings.Repeat("a", 65)}, make([]string, maxUsedLocalCallIDs+1)} {
		if _, err := NewStreamWithLocalTools(makePolicy(used)); err == nil {
			t.Fatal("invalid used IDs accepted", used)
		}
	}
	used := make([]string, maxUsedLocalCallIDs)
	for i := range used {
		used[i] = fmt.Sprintf("%060d_%03d", i, i)
	}
	if _, err := NewStreamWithLocalTools(makePolicy(used)); err != nil {
		t.Fatal("valid max-size used IDs rejected", err)
	}
}

func TestLocalToolsLargeImageContinuationHasBounded64MiBPath(t *testing.T) {
	// A real image result may exceed the ordinary 16 MiB request limit. It must
	// survive the complete stateless round trip, without dropping image/reasoning.
	image := strings.Repeat("A", 17*1024*1024)
	config := localTestConfig()
	config["continuation"] = []any{
		map[string]any{"type": "reasoning", "summary": []any{}, "encrypted_content": "opaque_large"},
		map[string]any{"type": "image_generation_call", "id": "ig_large", "result": image, "output_format": "png"},
		localTestCall("call_large", ""),
		map[string]any{"type": "function_call_output", "call_id": "call_large", "output": "ok"},
	}
	body, err := localTestRequest(config)
	if err != nil {
		t.Fatal(err)
	}
	input := body["input"].([]any)
	if input[2].(map[string]any)["result"] != image || input[1].(map[string]any)["encrypted_content"] != "opaque_large" {
		t.Fatal("large opaque output was lost")
	}
	ordinary := localTestConfig()
	delete(ordinary, "local_tools")
	ordinary["messages"] = []map[string]string{{"role": "user", "content": image}}
	if _, err := localTestRequest(ordinary); err == nil {
		t.Fatal("ordinary request bypassed 16 MiB cap")
	}
	if _, err := BuildRequest(strings.Repeat(" ", maxToolRequestBytes+1)); err == nil {
		t.Fatal("64 MiB cap bypassed")
	}
}

func TestLocalToolsCorrectableArgumentsAreExposedForExecutorErrors(t *testing.T) {
	stream, err := NewStreamWithLocalTools(`{"local_tools":["create_skill"],"namespace":""}`)
	if err != nil {
		t.Fatal(err)
	}
	call := map[string]any{"type": "function_call", "call_id": "call_bad_skill", "name": "create_skill", "arguments": `{"name":"BAD","body":""}`}
	if _, err := stream.Push(localTestTerminal([]any{call})); err != nil {
		t.Fatal("business error discarded completed response", err)
	}
	result, err := stream.Finish()
	if err != nil {
		t.Fatal(err)
	}
	var decoded streamResult
	if json.Unmarshal([]byte(result), &decoded) != nil || len(decoded.FunctionCalls) != 1 {
		t.Fatal(result)
	}
}

func TestCompletedOutputSharesFinishBoundaryAndPreservesRawJSON(t *testing.T) {
	const rawOutput = `[ {"type":"reasoning","encrypted_content":"opaque+/=","summary":[],"large_integer":9007199254740993}, {"type":"image_generation_call","result":"AA=="} ]`
	stream := localTestPolicy(t, "")
	if _, err := stream.Push([]byte(`data: {"type":"response.completed","response":{"status":"completed","output":` + rawOutput + "}}\n\n")); err != nil {
		t.Fatal(err)
	}
	output, err := stream.CompletedOutput()
	if err != nil || output != rawOutput {
		t.Fatal("raw output changed", output, err)
	}
	if _, err := stream.Finish(); err != nil {
		t.Fatal(err)
	}
	if again, err := stream.CompletedOutput(); err != nil || again != output {
		t.Fatal("getter changed state", again, err)
	}
	for _, missing := range []string{"", `,"output":null`, `,"output":[]`} {
		stream := NewStream()
		if _, err := stream.Push([]byte(`data: {"type":"response.completed","response":{"status":"completed"` + missing + "}}\n\n")); err != nil {
			t.Fatal(err)
		}
		if output, err := stream.CompletedOutput(); err != nil || output != "[]" {
			t.Fatal(output, err)
		}
	}
	for label, prepare := range map[string]func(*Stream){
		"unfinished": func(s *Stream) {
			_, _ = s.Push([]byte("data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"))
		},
		"failure":           func(s *Stream) { _, _ = s.Push([]byte("data: {\"type\":\"response.failed\"}\n\n")) },
		"truncated buffer":  func(s *Stream) { _, _ = s.Push(localTestTerminal([]any{})); _, _ = s.Push([]byte("data: {")) },
		"uncommitted event": func(s *Stream) { _, _ = s.Push(localTestTerminal([]any{})); _, _ = s.Push([]byte("data: {}\n")) },
	} {
		t.Run(label, func(t *testing.T) {
			for _, getterFirst := range []bool{true, false} {
				stream := NewStream()
				prepare(stream)
				var output, final string
				var outputErr, finishErr error
				if getterFirst {
					output, outputErr = stream.CompletedOutput()
					final, finishErr = stream.Finish()
				} else {
					final, finishErr = stream.Finish()
					output, outputErr = stream.CompletedOutput()
				}
				if outputErr == nil || finishErr == nil || outputErr.Error() != finishErr.Error() || output != "" || final != "" {
					t.Fatal("readers disagree", outputErr, finishErr)
				}
			}
		})
	}
}
