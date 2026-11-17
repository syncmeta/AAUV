package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"

	copilot "github.com/github/copilot-sdk/go"
	"github.com/github/copilot-sdk/go/rpc"
	"github.com/google/jsonschema-go/jsonschema"
	"github.com/google/uuid"
)

const (
	toolFrameLimit   = 16 * 1024 * 1024
	toolTextLimit    = 1024 * 1024
	toolOutputLimit  = 32 * 1024 * 1024
	toolPendingLimit = 8
	toolCallLimit    = 64
)

var errToolProtocol = errors.New("local tool protocol failed")
var localToolNames = map[string]bool{
	"search_chat_history": true, "create_skill": true, "read_attachment": true,
	"send_images": true, "delegate_to_specialist": true,
}
var toolErrorCodes = map[string]bool{
	"invalid_arguments": true, "stale_context": true, "not_found": true, "not_allowed": true,
	"failed": true, "cancelled": true, "limit_exceeded": true,
}

type localToolSpec struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}
type localToolResult struct {
	Type      string `json:"type"`
	RequestID string `json:"request_id"`
	CallID    string `json:"call_id"`
	Status    string `json:"status"`
	Text      string `json:"text"`
	Code      string `json:"code,omitempty"`
}
type pendingLocalTool struct {
	state  string
	result chan localToolResult
}
type localToolBridge struct {
	ctx                        context.Context
	cancel                     context.CancelFunc
	req                        request
	write                      func(event) error
	specs                      []localToolSpec
	schemas                    map[string]*jsonschema.Resolved
	mu                         sync.Mutex
	started                    bool
	sessionID                  string
	pending                    map[string]*pendingLocalTool
	active, calls, outputBytes int
	preparedImages             bool
	readerCloser               io.Closer
	stopReader                 func() bool
}

func (b *localToolBridge) hasPreparedImages() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.preparedImages
}

func strictJSON(data []byte, value any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(value); err != nil {
		return errToolProtocol
	}
	if d.Decode(new(any)) != io.EOF {
		return errToolProtocol
	}
	return nil
}

func newLocalToolBridge(ctx context.Context, cancel context.CancelFunc, req request, write func(event) error) (*localToolBridge, error) {
	b := &localToolBridge{ctx: ctx, cancel: cancel, req: req, write: write, schemas: map[string]*jsonschema.Resolved{}, pending: map[string]*pendingLocalTool{}}
	if req.BridgeProtocol == 0 && len(req.LocalTools) == 0 && req.RequestID == "" {
		return b, nil
	}
	if req.BridgeProtocol != 2 || len(req.RequestID) > 64 {
		return nil, errToolProtocol
	}
	if _, err := uuid.Parse(req.RequestID); err != nil {
		return nil, errToolProtocol
	}
	if len(req.LocalTools) == 0 {
		return b, nil
	}
	if bytes.Equal(bytes.TrimSpace(req.LocalTools), []byte("null")) || strictJSON(req.LocalTools, &b.specs) != nil || len(b.specs) > len(localToolNames) {
		return nil, errToolProtocol
	}
	for _, spec := range b.specs {
		if !localToolNames[spec.Name] || b.schemas[spec.Name] != nil || spec.Parameters == nil || spec.Parameters["type"] != "object" || len(spec.Description) > 4096 {
			return nil, errToolProtocol
		}
		data, err := json.Marshal(spec.Parameters)
		if err != nil || len(data) > 64*1024 {
			return nil, errToolProtocol
		}
		var schema jsonschema.Schema
		if json.Unmarshal(data, &schema) != nil {
			return nil, errToolProtocol
		}
		resolved, err := schema.Resolve(nil) // nil loader forbids remote schema loading.
		if err != nil {
			return nil, errToolProtocol
		}
		b.schemas[spec.Name] = resolved
	}
	return b, nil
}
func (b *localToolBridge) fail() { b.cancel() }
func (b *localToolBridge) close() {
	b.cancel()
	if b.stopReader != nil {
		b.stopReader()
	}
	if b.readerCloser != nil {
		_ = b.readerCloser.Close()
	}
}
func (b *localToolBridge) hasTool(name string) bool { return b.schemas[name] != nil }
func (b *localToolBridge) availableTools() []string {
	a := []string{}
	for _, s := range b.specs {
		a = append(a, "custom:"+s.Name)
	}
	return a
}
func (b *localToolBridge) tools() []copilot.Tool {
	a := []copilot.Tool{}
	for _, spec := range b.specs {
		s := spec
		a = append(a, copilot.Tool{Name: s.Name, Description: s.Description, Parameters: s.Parameters, SkipPermission: true, Defer: copilot.ToolDeferNever, Handler: func(inv copilot.ToolInvocation) (copilot.ToolResult, error) { return b.invoke(s.Name, inv) }})
	}
	return a
}
func (b *localToolBridge) validMetadata(m *rpc.ToolsGetCurrentMetadataResult) bool {
	if m == nil || m.Tools == nil || len(m.Tools) != len(b.specs) {
		return false
	}
	seen := map[string]bool{}
	for _, t := range m.Tools {
		if t.DeferLoading != nil && *t.DeferLoading || !b.hasTool(t.Name) || seen[t.Name] || t.MCPServerName != nil && *t.MCPServerName != "" || t.MCPToolName != nil && *t.MCPToolName != "" {
			return false
		}
		seen[t.Name] = true
	}
	return true
}
func (b *localToolBridge) authorize(input io.Reader, stage string) error {
	if err := b.ctx.Err(); err != nil {
		return err
	}
	if err := b.write(event{Type: stage, BridgeProtocol: b.req.BridgeProtocol, RequestID: b.req.RequestID}); err != nil {
		return err
	}
	var ack [1]byte
	if _, err := io.ReadFull(input, ack[:]); err != nil || ack[0] != 1 {
		return errToolProtocol
	}
	return b.ctx.Err()
}
func (b *localToolBridge) start(input io.Reader, sessionID string) {
	b.mu.Lock()
	b.started = true
	b.sessionID = sessionID
	b.mu.Unlock()
	if b.req.BridgeProtocol != 2 {
		return
	}
	if closer, ok := input.(io.Closer); ok {
		b.readerCloser = closer
		b.stopReader = context.AfterFunc(b.ctx, func() { _ = closer.Close() })
	}
	go b.readResults(input)
}
func (b *localToolBridge) readResults(input io.Reader) {
	for {
		var n uint32
		if binary.Read(input, binary.BigEndian, &n) != nil || n == 0 || n > toolFrameLimit {
			b.fail()
			return
		}
		data := make([]byte, n)
		if _, err := io.ReadFull(input, data); err != nil {
			b.fail()
			return
		}
		if b.acceptResult(data) != nil {
			b.fail()
			return
		}
	}
}
func (b *localToolBridge) acceptResult(data []byte) error {
	var r localToolResult
	if strictJSON(data, &r) != nil || r.Type != "tool_result" || r.RequestID != b.req.RequestID || len(r.Text) > toolTextLimit {
		return errToolProtocol
	}
	if r.Status == "ok" {
		if r.Text == "" || r.Code != "" {
			return errToolProtocol
		}
	} else if r.Status != "error" || !toolErrorCodes[r.Code] {
		return errToolProtocol
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	p := b.pending[r.CallID]
	if p == nil {
		return errToolProtocol
	}
	if p.state == "cancelled" || b.ctx.Err() != nil {
		return nil
	} // A late result never revives work.
	if p.state != "pending" {
		return errToolProtocol
	}
	p.state = "result"
	p.result <- r
	return nil
}
func (b *localToolBridge) emit(e event) error {
	data, err := json.Marshal(e)
	if err != nil || len(data) > toolFrameLimit {
		return errToolProtocol
	}
	b.mu.Lock()
	b.outputBytes += len(data) + 1
	tooLarge := b.outputBytes > toolOutputLimit
	b.mu.Unlock()
	if tooLarge {
		return errToolProtocol
	}
	return b.write(e)
}
func toolFailure(code string) copilot.ToolResult {
	return copilot.ToolResult{ResultType: "failure", Error: code, TextResultForLLM: "AAUV tool failed: " + code}
}
func (b *localToolBridge) invoke(name string, inv copilot.ToolInvocation) (copilot.ToolResult, error) {
	b.mu.Lock()
	if !b.started || inv.SessionID != b.sessionID {
		b.mu.Unlock()
		b.fail()
		return toolFailure("not_allowed"), nil
	}
	if b.calls >= toolCallLimit {
		b.mu.Unlock()
		b.fail()
		return toolFailure("limit_exceeded"), nil
	}
	b.calls++
	b.mu.Unlock()
	if inv.ToolName != name || inv.AgentID != "" || inv.RequestID == "" || inv.ToolCallID == "" || inv.TraceContext == nil {
		return toolFailure("not_allowed"), nil
	}
	args, ok := inv.Arguments.(map[string]any)
	if !ok || b.schemas[name] == nil || b.schemas[name].Validate(args) != nil {
		return toolFailure("invalid_arguments"), nil
	}
	ctx, cancel := context.WithCancel(b.ctx)
	defer cancel()
	stop := context.AfterFunc(inv.TraceContext, cancel)
	defer stop()
	if inv.TraceContext.Err() != nil {
		cancel()
	}
	if ctx.Err() != nil {
		return toolFailure("cancelled"), nil
	}
	b.mu.Lock()
	if !b.started || inv.SessionID != b.sessionID || b.active >= toolPendingLimit {
		b.mu.Unlock()
		b.fail()
		return toolFailure("limit_exceeded"), nil
	}
	id := uuid.NewString()
	p := &pendingLocalTool{state: "pending", result: make(chan localToolResult, 1)}
	b.pending[id] = p
	b.active++
	b.mu.Unlock()
	defer func() { b.mu.Lock(); b.active--; b.mu.Unlock() }()
	if err := b.emit(event{Type: "tool_call", RequestID: b.req.RequestID, CallID: id, Name: name, Arguments: args}); err != nil {
		b.fail()
		return toolFailure("failed"), nil
	}
	select {
	case r := <-p.result:
		if ctx.Err() != nil {
			return toolFailure("cancelled"), nil
		}
		if r.Status == "error" {
			return toolFailure(r.Code), nil
		}
		if name == "send_images" {
			var result struct {
				Sent int `json:"sent"`
			}
			if json.Unmarshal([]byte(r.Text), &result) == nil && result.Sent > 0 && result.Sent <= 5 {
				b.mu.Lock()
				b.preparedImages = true
				b.mu.Unlock()
			}
		}
		return copilot.ToolResult{ResultType: "success", TextResultForLLM: r.Text}, nil
	case <-ctx.Done():
		b.mu.Lock()
		p.state = "cancelled"
		b.mu.Unlock()
		if b.ctx.Err() == nil {
			if b.emit(event{Type: "tool_cancel", RequestID: b.req.RequestID, CallID: id}) != nil {
				b.fail()
			}
		}
		return toolFailure("cancelled"), nil
	}
}
