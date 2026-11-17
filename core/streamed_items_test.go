package aauvcore

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func streamedItem(t *testing.T, item any, index *int) []byte {
	t.Helper()
	event := map[string]any{"type": "response.output_item.done", "item": item}
	if index != nil {
		event["output_index"] = *index
	}
	data, err := json.Marshal(event)
	if err != nil {
		t.Fatal(err)
	}
	return []byte("data: " + string(data) + "\n\n")
}

func streamIndex(value int) *int { return &value }

func assertNoStreamResult(t *testing.T, stream *Stream) {
	t.Helper()
	if value, err := stream.Finish(); err == nil || value != "" {
		t.Fatal("unfinished/failed stream exposed a result", value, err)
	}
	if value, err := stream.CompletedOutput(); err == nil || value != "" {
		t.Fatal("unfinished/failed stream exposed replay items", value, err)
	}
}

func TestStreamedItemsObservedCompletedCallWithEmptyTerminal(t *testing.T) {
	// Constructed from the actual observed item/terminal shapes (shape log SHA
	// 15505f43...), not a raw wire replay. That log did NOT record output_index.
	// Both index variants below are synthetic coverage, not a claim about wire.
	for _, indexed := range []bool{false, true} {
		t.Run(fmt.Sprint(indexed), func(t *testing.T) {
			stream := localTestPolicy(t, "aauv")
			call := localTestCall("call_observed_shape", "aauv")
			call["arguments"] = `{"limit":10,"query":"AAUV_OK","since":null,"until":null}`
			var index *int
			if indexed {
				index = streamIndex(0)
			}
			for _, b := range streamedItem(t, call, index) {
				if _, err := stream.Push([]byte{b}); err != nil {
					t.Fatal(err)
				}
			}
			if len(stream.result.FunctionCalls) != 0 || len(stream.result.Output) != 0 {
				t.Fatal("done item published before successful terminal")
			}
			terminal := `data: {"type":"response.completed","response":{"status":"completed","id":"resp_synthetic","output":[],"usage":{"input_tokens":1119,"output_tokens":33,"total_tokens":1152}}}` + "\n\n"
			if _, err := stream.Push([]byte(terminal)); err != nil {
				t.Fatal(err)
			}
			value, err := stream.Finish()
			if err != nil {
				t.Fatal(err)
			}
			var result streamResult
			if json.Unmarshal([]byte(value), &result) != nil || len(result.FunctionCalls) != 1 || result.FunctionCalls[0].Arguments != call["arguments"] || result.FunctionCalls[0].Namespace != "aauv" || result.Text != "" {
				t.Fatal("completed streamed call was lost", value)
			}
			if string(result.Usage) != `{"input_tokens":1119,"output_tokens":33,"total_tokens":1152}` {
				t.Fatal("usage changed", string(result.Usage))
			}
			output, err := stream.CompletedOutput()
			if err != nil || !strings.Contains(output, `"function_call"`) || strings.Contains(output, `"reasoning"`) {
				t.Fatal("missing call or fabricated reasoning", output, err)
			}
		})
	}
}

func TestStreamedItemsSyntheticMissingAndNullTerminalOutput(t *testing.T) {
	// Missing/null output are compatibility cases, not this real shape trace.
	for _, field := range []string{"", `,"output":null`, `,"output":[ ]`} {
		stream := localTestPolicy(t, "")
		if _, err := stream.Push(streamedItem(t, localTestCall("call_1", ""), nil)); err != nil {
			t.Fatal(err)
		}
		if _, err := stream.Push([]byte(`data: {"type":"response.completed","response":{"status":"completed"` + field + "}}\n\n")); err != nil {
			t.Fatal(err)
		}
		value, err := stream.Finish()
		var result streamResult
		if err != nil || json.Unmarshal([]byte(value), &result) != nil || len(result.FunctionCalls) != 1 {
			t.Fatal(field, value, err)
		}
	}
}

func TestStreamedItemsSyntheticCallWithoutStatus(t *testing.T) {
	// The original terminal parseCall contract permits absent status. Keep it
	// for a complete done event, but still require a successful full terminal.
	call := localTestCall("call_no_status", "")
	delete(call, "status")
	unfinished := localTestPolicy(t, "")
	_, _ = unfinished.Push(streamedItem(t, call, nil))
	assertNoStreamResult(t, unfinished)
	stream := localTestPolicy(t, "")
	_, _ = stream.Push(streamedItem(t, call, nil))
	if len(stream.result.FunctionCalls) != 0 {
		t.Fatal("call escaped before terminal")
	}
	if _, err := stream.Push(localTestTerminal([]any{})); err != nil {
		t.Fatal(err)
	}
	value, err := stream.Finish()
	var result streamResult
	if err != nil || json.Unmarshal([]byte(value), &result) != nil || len(result.FunctionCalls) != 1 {
		t.Fatal(value, err)
	}
}

func TestStreamedItemsRequireSuccessfulFullTerminal(t *testing.T) {
	for _, tail := range []string{
		"", "data: [DONE]\n\n", `data: {"type":"response.completed","response":{"status":"completed","output":[]}}` + "\n",
		`data: {"type":"response.failed"}` + "\n\n", `data: {"type":"error"}` + "\n\n",
		`data: {"type":"response.incomplete"}` + "\n\n", `data: {"type":"response.cancelled"}` + "\n\n",
		`data: {"type":"response.completed","response":{"status":"in_progress","output":[]}}` + "\n\n",
		`data: {"type":"response.completed","response":{"status":"failed","output":[]}}` + "\n\n",
		`data: {"type":"response.completed","response":{"output":[]}}` + "\n\n",
	} {
		stream := localTestPolicy(t, "")
		_, _ = stream.Push(streamedItem(t, localTestCall("call_1", ""), nil))
		if tail != "" {
			_, _ = stream.Push([]byte(tail))
		}
		assertNoStreamResult(t, stream)
	}
	for _, eventType := range []string{"response.output_item.added", "response.function_call_arguments.delta", "response.function_call_arguments.done"} {
		event, _ := json.Marshal(map[string]any{"type": eventType, "item": localTestCall("call_1", ""), "arguments": `{"query":"x"}`, "delta": `{"query":"x"}`})
		stream := localTestPolicy(t, "")
		if _, err := stream.Push([]byte("data: " + string(event) + "\n\n")); err != nil {
			t.Fatal(err)
		}
		if _, err := stream.Push(localTestTerminal([]any{})); err != nil {
			t.Fatal(err)
		}
		value, err := stream.Finish()
		var result streamResult
		if err != nil || json.Unmarshal([]byte(value), &result) != nil || len(result.FunctionCalls) != 0 {
			t.Fatal("executed a non-done source", eventType, value, err)
		}
	}
	stream := localTestPolicy(t, "")
	_, _ = stream.Push(streamedItem(t, localTestCall("call_1", ""), nil))
	_, _ = stream.Push(localTestTerminal([]any{}))
	_, _ = stream.Push([]byte("data: {"))
	assertNoStreamResult(t, stream)
}

func TestStreamedItemsFallbackPreservesToolGuards(t *testing.T) {
	mutations := map[string]func(map[string]any){
		"incomplete":          func(c map[string]any) { c["status"] = "in_progress" },
		"incomplete status":   func(c map[string]any) { c["status"] = "incomplete" },
		"failed":              func(c map[string]any) { c["status"] = "failed" },
		"cancelled":           func(c map[string]any) { c["status"] = "cancelled" },
		"null status":         func(c map[string]any) { c["status"] = nil },
		"invalid status type": func(c map[string]any) { c["status"] = true },
		"not allowed":         func(c map[string]any) { c["name"] = "execute_code" },
		"namespace":           func(c map[string]any) { c["namespace"] = "aauv" },
		"call ID":             func(c map[string]any) { c["call_id"] = "bad\nID" },
		"arguments":           func(c map[string]any) { c["arguments"] = "[]" },
		"duplicate args":      func(c map[string]any) { c["arguments"] = `{"query":"x","query":"y"}` },
		"injection":           func(c map[string]any) { c["tools"] = []any{} },
		"caller":              func(c map[string]any) { c["caller"] = map[string]any{"type": "code_interpreter"} },
		"async":               func(c map[string]any) { c["async"] = true },
	}
	for label, mutate := range mutations {
		t.Run(label, func(t *testing.T) {
			stream := localTestPolicy(t, "")
			call := localTestCall("call_1", "")
			mutate(call)
			_, _ = stream.Push(streamedItem(t, call, nil))
			if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
				t.Fatal("unsafe fallback accepted", label)
			}
			assertNoStreamResult(t, stream)
		})
	}
	for _, policy := range []string{"", `{"local_tools":[],"namespace":""}`, `{"local_tools":["search_chat_history"],"namespace":"","used_call_ids":["call_1"]}`} {
		stream := NewStream()
		if policy != "" {
			var err error
			stream, err = NewStreamWithLocalTools(policy)
			if err != nil {
				t.Fatal(err)
			}
		}
		_, _ = stream.Push(streamedItem(t, localTestCall("call_1", ""), nil))
		if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
			t.Fatal("disabled/reused call accepted", policy)
		}
		assertNoStreamResult(t, stream)
	}
	for _, raw := range []string{
		`{"type":"response.output_item.done","item":{"type":"function_call","type":"reasoning"}}`,
		`{"type":"response.output_item.done","item":{"type":"reasoning","summary":[],"tools":[]}}`,
		`{"type":"response.output_item.done","item":{"type":"custom_tool_call"}}`,
		`{"type":"response.output_item.done","item":null}`,
		`{"type":"response.output_item.done","item":{}}`,
	} {
		stream := localTestPolicy(t, "")
		_, _ = stream.Push([]byte("data: " + raw + "\n\n"))
		if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
			t.Fatal("invalid item accepted", raw)
		}
		assertNoStreamResult(t, stream)
	}
}

func TestStreamedItemsFallbackRejectsAmbiguityAndBounds(t *testing.T) {
	for label, indices := range map[string][]*int{
		"negative": {streamIndex(-1)}, "oversized": {streamIndex(maxContinuationItems)},
		"duplicate index": {streamIndex(0), streamIndex(0)}, "mixed": {nil, streamIndex(0)},
		"first gap": {streamIndex(1)}, "later gap": {streamIndex(0), streamIndex(2)},
	} {
		t.Run(label, func(t *testing.T) {
			stream := localTestPolicy(t, "")
			for i, index := range indices {
				_, _ = stream.Push(streamedItem(t, localTestCall(fmt.Sprintf("call_%d", i), ""), index))
			}
			if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
				t.Fatal("ambiguous fallback accepted")
			}
			assertNoStreamResult(t, stream)
		})
	}
	for _, duplicateItemID := range []bool{false, true} {
		stream := localTestPolicy(t, "")
		first, second := localTestCall("call_1", ""), localTestCall("call_2", "")
		if duplicateItemID {
			second["id"] = first["id"]
		} else {
			second["call_id"] = first["call_id"]
		}
		_, _ = stream.Push(streamedItem(t, first, nil))
		_, _ = stream.Push(streamedItem(t, second, nil))
		if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
			t.Fatal("duplicate fallback IDs accepted")
		}
		assertNoStreamResult(t, stream)
	}
	for _, limit := range []int{maxLocalCalls + 1, maxContinuationItems + 1} {
		stream := localTestPolicy(t, "")
		for i := 0; i < limit; i++ {
			var item any = localTestCall(fmt.Sprintf("call_%d", i), "")
			if limit > maxContinuationItems {
				item = map[string]any{"type": "reasoning", "id": fmt.Sprintf("rs_%d", i), "summary": []any{}}
			}
			_, _ = stream.Push(streamedItem(t, item, nil))
		}
		if _, err := stream.Push(localTestTerminal([]any{})); err == nil {
			t.Fatal("unbounded fallback accepted", limit)
		}
	}
	stream := localTestPolicy(t, "")
	for i := 0; i < 2; i++ {
		item := map[string]any{"type": "reasoning", "id": fmt.Sprintf("rs_%d", i), "encrypted_content": strings.Repeat("A", maxContinuationBytes/2)}
		if _, err := stream.Push(streamedItem(t, item, nil)); err != nil {
			t.Fatal("individual event should fit", err)
		}
	}
	if _, err := stream.Push(localTestTerminal([]any{})); err == nil || err.Error() != "continuation_too_large" {
		t.Fatal("aggregate bytes were not bounded", err)
	}
	assertNoStreamResult(t, stream)
}

func TestStreamedItemsRawContinuationAndIndexedOrder(t *testing.T) {
	// Opaque reasoning is synthetic test data, absent from the observed run.
	const reasoning = `{ "type":"reasoning","id":"rs_synthetic","summary":[],"encrypted_content":"SYNTHETIC+/=","future_integer":9007199254740993 }`
	const message = `{"type":"message","id":"msg_synthetic","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Looking up.","annotations":[]}]}`
	call, _ := json.Marshal(localTestCall("call_1", "aauv"))
	raw := []string{reasoning, message, string(call)}
	stream := localTestPolicy(t, "aauv")
	for _, index := range []int{2, 0, 1} {
		event := fmt.Sprintf("data: {\"type\":\"response.output_item.done\",\"output_index\":%d,\"item\":%s}\n\n", index, raw[index])
		if _, err := stream.Push([]byte(event)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := stream.Push(localTestTerminal([]any{})); err != nil {
		t.Fatal(err)
	}
	output, err := stream.CompletedOutput()
	if err != nil || output != "["+strings.Join(raw, ",")+"]" {
		t.Fatal("raw item bytes/order changed", output, err)
	}
	value, err := stream.Finish()
	var result streamResult
	if err != nil || json.Unmarshal([]byte(value), &result) != nil || result.Text != "Looking up." || len(result.FunctionCalls) != 1 {
		t.Fatal(value, err)
	}
	var continuation []json.RawMessage
	_ = json.Unmarshal([]byte(output), &continuation)
	continuation = append(continuation, json.RawMessage(`{"type":"function_call_output","call_id":"call_1","output":"[]"}`))
	config := localTestConfig()
	config["credential_kind"] = "chatgpt_plan"
	config["continuation"] = continuation
	encoded, _ := json.Marshal(config)
	plan, err := BuildRequest(string(encoded))
	if err != nil || !strings.Contains(plan, "9007199254740993") || !strings.Contains(plan, "SYNTHETIC+/=") || !strings.Contains(plan, "commentary") {
		t.Fatal("raw replay failed", err)
	}
}

func TestStreamedItemsHostedAndContainerFilesWithoutLocalPolicy(t *testing.T) {
	const message = `{"type":"message","id":"msg_hosted_synthetic","role":"assistant","content":[{"type":"output_text","text":"Synthetic hosted result","annotations":[{"type":"container_file_citation","container_id":"cntr_synthetic","file_id":"cfile_synthetic","filename":"synthetic.png"}]}]}`
	const image = `{ "type":"image_generation_call","id":"ig_synthetic","status":"completed","result":"AA==","output_format":"png","provider_metadata":{"synthetic":true,"integer":9007199254740993} }`
	stream := NewStream()
	for index, raw := range []string{message, image} {
		event := fmt.Sprintf("data: {\"type\":\"response.output_item.done\",\"output_index\":%d,\"item\":%s}\n\n", index, raw)
		if _, err := stream.Push([]byte(event)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := stream.Push(localTestTerminal([]any{})); err != nil {
		t.Fatal(err)
	}
	value, err := stream.Finish()
	var result streamResult
	if err != nil || json.Unmarshal([]byte(value), &result) != nil {
		t.Fatal(value, err)
	}
	wantFile := containerFile{Type: "container_file_citation", ContainerID: "cntr_synthetic", FileID: "cfile_synthetic", Filename: "synthetic.png"}
	if result.Text != "Synthetic hosted result" || len(result.Files) != 1 || result.Files[0] != wantFile || len(result.FunctionCalls) != 0 {
		t.Fatal("hosted fallback lost text/file metadata or became locally executable", value)
	}
	output, err := stream.CompletedOutput()
	if err != nil || output != "["+message+","+image+"]" {
		t.Fatal("hosted raw items changed", output, err)
	}
}

func TestStreamedItemsNonemptyTerminalRemainsSoleAuthority(t *testing.T) {
	// Different call IDs/arguments, reordered fields, extra allowed metadata,
	// and terminal-only opaque values must not cause merging or lossy comparison.
	const output = `[ {"status":"completed","call_id":"call_terminal","type":"function_call","name":"search_chat_history","arguments":"{\"query\":\"terminal\"}","caller":{"type":"direct"},"namespace":"aauv","id":"fc_terminal","async":false}, {"type":"reasoning","summary":[],"encrypted_content":"SYNTHETIC terminal","integer":9007199254740993} ]`
	for _, duplicateDone := range []bool{false, true} {
		stream := localTestPolicy(t, "aauv")
		_, _ = stream.Push(streamedItem(t, localTestCall("call_streamed", "aauv"), streamIndex(0)))
		if duplicateDone {
			_, _ = stream.Push(streamedItem(t, localTestCall("call_streamed", "aauv"), streamIndex(0)))
		}
		if _, err := stream.Push([]byte(`data: {"type":"response.completed","response":{"status":"completed","output":` + output + "}}\n\n")); err != nil {
			t.Fatal(err)
		}
		raw, err := stream.CompletedOutput()
		if err != nil || raw != output {
			t.Fatal("terminal bytes changed", raw, err)
		}
		value, err := stream.Finish()
		var result streamResult
		if err != nil || json.Unmarshal([]byte(value), &result) != nil || len(result.FunctionCalls) != 1 || result.FunctionCalls[0].CallID != "call_terminal" {
			t.Fatal("double/incorrect call", value, err)
		}
	}
	stream := localTestPolicy(t, "aauv")
	_, _ = stream.Push(streamedItem(t, localTestCall("call_streamed", "aauv"), nil))
	if _, err := stream.Push(localTestTerminal([]any{localTestCall("call_bad_namespace", "")})); err == nil {
		t.Fatal("buffered valid call masked unsafe terminal")
	}
	assertNoStreamResult(t, stream)
}

func TestStreamedItemsConcurrentPolicyIsolation(t *testing.T) {
	for i := 0; i < 24; i++ {
		t.Run(fmt.Sprint(i), func(t *testing.T) {
			t.Parallel()
			namespace := ""
			if i%2 == 0 {
				namespace = "aauv"
			}
			stream := localTestPolicy(t, namespace)
			if _, err := stream.Push(streamedItem(t, localTestCall("call_same_across_independent_streams", namespace), nil)); err != nil {
				t.Fatal(err)
			}
			if _, err := stream.Push(localTestTerminal([]any{})); err != nil {
				t.Fatal(err)
			}
			if _, err := stream.Finish(); err != nil {
				t.Fatal(err)
			}
		})
	}
}
