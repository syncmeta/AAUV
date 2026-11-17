package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	copilot "github.com/github/copilot-sdk/go"
	"github.com/github/copilot-sdk/go/rpc"
)

const fixtureID = "d0626055-56ed-4742-a888-4e64f5b6b0a5"

func fixtureRequest() request {
	specs := []localToolSpec{}
	for _, name := range []string{"search_chat_history", "create_skill", "read_attachment", "send_images", "delegate_to_specialist"} {
		specs = append(specs, localToolSpec{Name: name, Description: "fixture", Parameters: map[string]any{"type": "object", "properties": map[string]any{"probe": map[string]any{"type": "boolean"}, "block": map[string]any{"type": "boolean"}}, "additionalProperties": false}})
	}
	data, _ := json.Marshal(specs)
	return request{BridgeProtocol: 2, RequestID: fixtureID, LocalTools: data, Token: "gho_reply_fixture", Messages: []message{{Role: "user", Content: "normal"}}}
}
func makeBridge(t *testing.T) (*localToolBridge, context.Context, context.CancelFunc, chan event) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	events := make(chan event, 128)
	b, err := newLocalToolBridge(ctx, cancel, fixtureRequest(), func(e event) error { events <- e; return nil })
	if err != nil {
		t.Fatal(err)
	}
	b.mu.Lock()
	b.started = true
	b.sessionID = "fixture-session"
	b.mu.Unlock()
	t.Cleanup(b.close)
	return b, ctx, cancel, events
}
func invocation(ctx context.Context) copilot.ToolInvocation {
	return copilot.ToolInvocation{SessionID: "fixture-session", ToolName: "search_chat_history", RequestID: "sdk-request", ToolCallID: "sdk-call", TraceContext: ctx, Arguments: map[string]any{"probe": true}}
}
func resultData(e event, status, code string) []byte {
	d, _ := json.Marshal(localToolResult{Type: "tool_result", RequestID: e.RequestID, CallID: e.CallID, Status: status, Text: "synthetic-only", Code: code})
	return d
}

func TestLocalToolDeclarations(t *testing.T) {
	r := fixtureRequest()
	for _, change := range []func(*request){func(r *request) { r.BridgeProtocol = 3 }, func(r *request) { r.RequestID = "invalid" }, func(r *request) { r.BridgeProtocol = 0 }, func(r *request) { r.LocalTools = json.RawMessage(`null`) }, func(r *request) { r.LocalTools = json.RawMessage(`[{"name":"shell","parameters":{"type":"object"}}]`) }, func(r *request) {
		r.LocalTools = json.RawMessage(`[{"name":"read_attachment","parameters":{"type":"object","required":"bad"}}]`)
	}, func(r *request) {
		r.LocalTools = json.RawMessage(`[{"name":"read_attachment","parameters":{"type":"object","$ref":"https://example.invalid/schema"}}]`)
	}} {
		bad := r
		change(&bad)
		ctx, cancel := context.WithCancel(context.Background())
		b, err := newLocalToolBridge(ctx, cancel, bad, func(event) error { return nil })
		cancel()
		if err == nil {
			b.close()
			t.Fatal("accepted invalid declaration")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	legacy, err := newLocalToolBridge(ctx, cancel, request{}, func(event) error { return nil })
	if err != nil || len(legacy.tools()) != 0 || legacy.availableTools() == nil {
		t.Fatal("legacy path is not explicitly zero tools")
	}
}
func TestLocalToolMetadata(t *testing.T) {
	b, _, _, _ := makeBridge(t)
	items := []rpc.CurrentToolMetadata{}
	for _, s := range b.specs {
		items = append(items, rpc.CurrentToolMetadata{Name: s.Name})
	}
	if !b.validMetadata(&rpc.ToolsGetCurrentMetadataResult{Tools: items}) {
		t.Fatal("valid metadata rejected")
	}
	if b.validMetadata(nil) || b.validMetadata(&rpc.ToolsGetCurrentMetadataResult{}) || b.validMetadata(&rpc.ToolsGetCurrentMetadataResult{Tools: append(items, rpc.CurrentToolMetadata{Name: "shell"})}) {
		t.Fatal("unexpected metadata accepted")
	}
	items[1] = items[0]
	if b.validMetadata(&rpc.ToolsGetCurrentMetadataResult{Tools: items}) {
		t.Fatal("duplicate accepted")
	}
	items[1] = rpc.CurrentToolMetadata{Name: b.specs[1].Name, MCPServerName: copilot.String("mcp")}
	if b.validMetadata(&rpc.ToolsGetCurrentMetadataResult{Tools: items}) {
		t.Fatal("MCP accepted")
	}
}
func TestLocalToolConcurrentResults(t *testing.T) {
	b, _, _, events := makeBridge(t)
	const n = 5
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, e := b.invoke("search_chat_history", invocation(context.Background()))
			if e != nil || r.TextResultForLLM != "synthetic-only" {
				t.Error("tool result mismatch")
			}
		}()
	}
	ids := map[string]bool{}
	calls := []event{}
	for i := 0; i < n; i++ {
		e := <-events
		if e.Type != "tool_call" || ids[e.CallID] {
			t.Fatal("bad call identity")
		}
		ids[e.CallID] = true
		calls = append(calls, e)
	}
	for i := n - 1; i >= 0; i-- {
		if b.acceptResult(resultData(calls[i], "ok", "")) != nil {
			t.Fatal("result rejected")
		}
	}
	wg.Wait()
	if b.acceptResult(resultData(calls[0], "ok", "")) == nil {
		t.Fatal("duplicate accepted")
	}
}
func TestLocalToolCancellationAndLateResult(t *testing.T) {
	b, _, _, events := makeBridge(t)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan copilot.ToolResult, 1)
	go func() { r, _ := b.invoke("search_chat_history", invocation(ctx)); done <- r }()
	call := <-events
	cancel()
	if r := <-done; r.Error != "cancelled" {
		t.Fatal("handler not cancelled")
	}
	if e := <-events; e.Type != "tool_cancel" || e.CallID != call.CallID {
		t.Fatal("missing cancel")
	}
	if b.acceptResult(resultData(call, "ok", "")) != nil {
		t.Fatal("known late result must be dropped")
	}
}
func TestLocalToolBadArgumentsAndFrames(t *testing.T) {
	b, ctx, _, events := makeBridge(t)
	inv := invocation(context.Background())
	inv.Arguments = map[string]any{"extra": "bad"}
	r, _ := b.invoke(inv.ToolName, inv)
	if r.Error != "invalid_arguments" || len(events) != 0 {
		t.Fatal("invalid arguments reached parent")
	}
	inv = invocation(context.Background())
	inv.AgentID = "sub-agent"
	r, _ = b.invoke(inv.ToolName, inv)
	if r.Error != "not_allowed" || len(events) != 0 {
		t.Fatal("sub-agent reached parent")
	}
	for _, data := range [][]byte{[]byte(`{`), []byte(`{"type":"tool_result","request_id":"wrong","call_id":"unknown","status":"ok","text":"x"}`), []byte(`{"type":"tool_result","request_id":"` + fixtureID + `","call_id":"unknown","status":"error","code":"raw-error"}`), []byte(`{"type":"tool_result","request_id":"` + fixtureID + `","call_id":"unknown","status":"ok","text":"x","images":[]}`)} {
		if b.acceptResult(data) == nil {
			t.Fatal("invalid result accepted")
		}
	}
	reader, writer := io.Pipe()
	b.start(reader, "fixture-session")
	_ = writer.Close()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("EOF did not cancel")
	}
}
func TestLocalToolLimits(t *testing.T) {
	b, ctx, _, events := makeBridge(t)
	var wg sync.WaitGroup
	for i := 0; i < toolPendingLimit; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = b.invoke("search_chat_history", invocation(context.Background())) }()
		<-events
	}
	r, _ := b.invoke("search_chat_history", invocation(context.Background()))
	if r.Error != "limit_exceeded" {
		t.Fatal("pending limit missing")
	}
	<-ctx.Done()
	wg.Wait()
	b, _, _, _ = makeBridge(t)
	b.calls = toolCallLimit
	r, _ = b.invoke("search_chat_history", invocation(context.Background()))
	if r.Error != "limit_exceeded" {
		t.Fatal("call limit missing")
	}
	b, _, _, _ = makeBridge(t)
	if b.emit(event{Type: "tool_call", Text: strings.Repeat("x", toolFrameLimit)}) == nil {
		t.Fatal("frame output limit missing")
	}
}

func runFixture(t *testing.T, req request, fixture string, onTool func(event) map[string]any) ([]event, error) {
	t.Helper()
	fixtureBytes, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	fixture = filepath.Join(t.TempDir(), "runtime-fixture")
	if err := os.WriteFile(fixture, fixtureBytes, 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	in, writer := io.Pipe()
	reader, out := io.Pipe()
	defer writer.Close()
	defer reader.Close()
	done := make(chan error, 1)
	go func() { err := run(ctx, fixture, in, json.NewEncoder(out)); done <- err; _ = out.Close() }()
	data, _ := json.Marshal(req)
	go func() { _ = binary.Write(writer, binary.BigEndian, uint32(len(data))); _, _ = writer.Write(data) }()
	items := []event{}
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), toolFrameLimit)
	for scanner.Scan() {
		var e event
		if json.Unmarshal(scanner.Bytes(), &e) != nil {
			t.Fatal("invalid output JSON")
		}
		items = append(items, e)
		if e.Type == "ready" || e.Type == "submit" {
			_, _ = writer.Write([]byte{1})
		}
		if e.Type == "tool_call" {
			r := onTool(e)
			d, _ := json.Marshal(r)
			_ = binary.Write(writer, binary.BigEndian, uint32(len(d)))
			_, _ = writer.Write(d)
		}
	}
	return items, <-done
}
func TestLocalToolSDKWireAndLegacyCatalog(t *testing.T) {
	fixture, _ := filepath.Abs("../Tests/copilot-tools-runtime-fixture.py")
	items, err := runFixture(t, fixtureRequest(), fixture, func(e event) map[string]any {
		return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": e.CallID, "status": "ok", "text": "synthetic-result"}
	})
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range items {
		if e.Type == "tool_call" {
			n++
		}
	}
	if n != 5 || items[len(items)-1].Type != "completed" {
		t.Fatal("custom tool chain failed")
	}
	legacy, _ := filepath.Abs("../Tests/copilot-runtime-fixture.py")
	for _, r := range []request{{Token: "gho_reply_fixture", Messages: []message{{Role: "user", Content: "使用默认模型"}}}, {Operation: "list_models", Token: "gho_catalog_fixture", Proxy: "http://127.0.0.1:18888"}} {
		items, err = runFixture(t, r, legacy, nil)
		if err != nil {
			t.Fatal(err)
		}
		if len(items) < 3 {
			t.Fatal("legacy contract failed")
		}
	}
}
func TestLocalToolSDKUnknownFrameStops(t *testing.T) {
	fixture, _ := filepath.Abs("../Tests/copilot-tools-runtime-fixture.py")
	_, err := runFixture(t, fixtureRequest(), fixture, func(e event) map[string]any {
		return map[string]any{"type": "tool_result", "request_id": e.RequestID, "call_id": "unknown", "status": "ok", "text": "synthetic-result"}
	})
	if err == nil {
		t.Fatal("unknown frame did not stop turn")
	}
}

func TestLocalToolTruncatedOversizeAndUnsupportedBeforeReady(t *testing.T) {
	for _, size := range []uint32{4, toolFrameLimit + 1} {
		b, ctx, _, _ := makeBridge(t)
		var data bytes.Buffer
		_ = binary.Write(&data, binary.BigEndian, size)
		_, _ = data.Write([]byte{1})
		b.readResults(&data)
		if ctx.Err() == nil {
			t.Fatal("invalid frame did not cancel")
		}
	}
	req := fixtureRequest()
	req.BridgeProtocol = 3
	data, _ := json.Marshal(req)
	var input, output bytes.Buffer
	_ = binary.Write(&input, binary.BigEndian, uint32(len(data)))
	_, _ = input.Write(data)
	if run(context.Background(), "/must-not-start", &input, json.NewEncoder(&output)) == nil || output.Len() != 0 {
		t.Fatal("unsupported protocol reached ready/runtime")
	}
	b, _, _, _ := makeBridge(t)
	d, _ := json.Marshal(localToolResult{Type: "tool_result", RequestID: fixtureID, CallID: "unknown", Status: "ok", Text: strings.Repeat("x", toolTextLimit+1)})
	if b.acceptResult(d) == nil {
		t.Fatal("oversized tool result accepted")
	}
}

func TestLocalToolSanitizedErrorAndParentCancellation(t *testing.T) {
	b, _, cancel, events := makeBridge(t)
	done := make(chan copilot.ToolResult, 1)
	go func() { r, _ := b.invoke("search_chat_history", invocation(context.Background())); done <- r }()
	e := <-events
	d, _ := json.Marshal(localToolResult{Type: "tool_result", RequestID: e.RequestID, CallID: e.CallID, Status: "error", Code: "failed", Text: "RAW_PRIVATE_SERVICE_ERROR"})
	if b.acceptResult(d) != nil {
		t.Fatal("fixed error rejected")
	}
	r := <-done
	if r.Error != "failed" || strings.Contains(r.TextResultForLLM, "PRIVATE") {
		t.Fatal("raw error forwarded")
	}
	go func() { r, _ := b.invoke("search_chat_history", invocation(context.Background())); done <- r }()
	e = <-events
	cancel()
	r = <-done
	if r.Error != "cancelled" {
		t.Fatal("parent cancellation ignored")
	}
	if b.acceptResult(resultData(e, "ok", "")) != nil {
		t.Fatal("late parent result was not dropped")
	}
}
