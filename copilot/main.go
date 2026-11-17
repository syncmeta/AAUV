// AAUV's local bridge to the official GitHub Copilot runtime.
package main

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/github/copilot-sdk/go"
	"github.com/github/copilot-sdk/go/rpc"
)

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type attachment struct {
	Name      string `json:"name"`
	MediaType string `json:"media_type"`
	Path      string `json:"path"`
	Size      int64  `json:"size"`
}

type request struct {
	BridgeProtocol int             `json:"bridge_protocol,omitempty"`
	RequestID      string          `json:"request_id,omitempty"`
	LocalTools     json.RawMessage `json:"local_tools,omitempty"`
	Operation      string          `json:"operation,omitempty"`
	Token          string          `json:"token"`
	Model          string          `json:"model"`
	Instructions   string          `json:"instructions"`
	Messages       []message       `json:"messages"`
	Files          []attachment    `json:"files"`
	Proxy          string          `json:"proxy"`
}

type usage struct {
	Input  int64 `json:"input_tokens"`
	Output int64 `json:"output_tokens"`
}

type catalogModel struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Allowed bool   `json:"allowed"`
}

type event struct {
	BridgeProtocol int            `json:"bridge_protocol,omitempty"`
	RequestID      string         `json:"request_id,omitempty"`
	CallID         string         `json:"call_id,omitempty"`
	Name           string         `json:"name,omitempty"`
	Arguments      any            `json:"arguments,omitempty"`
	Type           string         `json:"type"`
	Text           string         `json:"text,omitempty"`
	Usage          *usage         `json:"usage,omitempty"`
	Models         []catalogModel `json:"models,omitempty"`
	Code           string         `json:"code,omitempty"`
}

func (e event) MarshalJSON() ([]byte, error) {
	type wireEvent event
	if e.Type == "completed" {
		// An explicit empty string is a successful image-only terminal, not an
		// absent/incomplete response. Other event shapes remain unchanged.
		return json.Marshal(struct {
			wireEvent
			Text string `json:"text"`
		}{wireEvent(e), e.Text})
	}
	return json.Marshal(wireEvent(e))
}

var errUnauthenticated = errors.New("copilot authentication required")

func main() {
	// A parent closes stdout before terminating us during cancellation. Handle
	// SIGPIPE through the context so SDK cleanup still stops the runtime child.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGPIPE)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	stopInputCancellation := context.AfterFunc(ctx, func() { _ = os.Stdin.Close() })
	defer stopInputCancellation()
	output := json.NewEncoder(os.Stdout)
	if len(os.Args) != 2 {
		_ = output.Encode(event{Type: "failed"})
		os.Exit(1)
	}
	if err := run(ctx, os.Args[1], os.Stdin, output); err != nil {
		// Upstream errors may contain sensitive details. Emit only fixed categories.
		failure := event{Type: "failed"}
		if errors.Is(err, errUnauthenticated) {
			failure.Code = "not_authenticated"
		}
		_ = output.Encode(failure)
		os.Exit(1)
	}
}

func run(ctx context.Context, runtime string, input io.Reader, output *json.Encoder) error {
	const maxInput = 16 * 1024 * 1024
	var length uint32
	if err := binary.Read(input, binary.BigEndian, &length); err != nil || length == 0 || length > maxInput {
		return errors.New("invalid request size")
	}
	data := make([]byte, length)
	if _, err := io.ReadFull(input, data); err != nil {
		return err
	}
	var req request
	if err := json.Unmarshal(data, &req); err != nil || req.Token == "" {
		return errors.New("invalid request")
	}
	ctx, stopRequest := context.WithCancel(ctx)
	defer stopRequest()
	var outputMutex sync.Mutex
	write := func(update event) error {
		outputMutex.Lock()
		defer outputMutex.Unlock()
		return output.Encode(update)
	}
	toolBridge, err := newLocalToolBridge(ctx, stopRequest, req, write)
	if err != nil {
		return err
	}
	defer toolBridge.close()
	var prompt string
	var files []copilot.Attachment
	switch req.Operation {
	case "", "reply":
		if len(req.Messages) == 0 {
			return errors.New("invalid request")
		}
		prompt, err = formatPrompt(req.Messages)
		if err != nil {
			return err
		}
		for _, file := range req.Files {
			blob, err := file.load(ctx)
			if err != nil {
				return err
			}
			files = append(files, blob)
		}
	case "list_models":
		if len(req.Messages) != 0 || len(req.Files) != 0 || req.Instructions != "" || req.BridgeProtocol != 0 {
			return errors.New("model catalog request includes chat data")
		}
	default:
		return errors.New("unsupported request")
	}
	// Check the app's credential and route after local attachment preparation.
	if err := toolBridge.authorize(input, "ready"); err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "aauv-copilot-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	env := []string{
		"HOME=" + dir, "TMPDIR=" + dir, "PATH=/usr/bin:/bin",
		"COPILOT_TELEMETRY_DISABLED=true",
	}
	if req.Proxy != "" {
		env = append(env, "HTTPS_PROXY="+req.Proxy, "HTTP_PROXY="+req.Proxy,
			"COPILOT_CLI_DISABLE_WEBSOCKET_RESPONSES=true")
	}
	client := copilot.NewClient(&copilot.ClientOptions{
		Connection:       copilot.StdioConnection{Path: runtime, Env: env},
		Mode:             copilot.ModeEmpty,
		BaseDirectory:    dir,
		WorkingDirectory: dir,
		GitHubToken:      req.Token,
		UseLoggedInUser:  copilot.Bool(false),
		LogLevel:         "none",
	})
	defer client.Stop()
	if req.Operation == "list_models" {
		listContext, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		return listModels(listContext, client, input, output)
	}
	session, err := client.CreateSession(ctx, &copilot.SessionConfig{
		Model:                 req.Model,
		ClientName:            "AAUV",
		Streaming:             copilot.Bool(true),
		AvailableTools:        toolBridge.availableTools(),
		Tools:                 toolBridge.tools(),
		EnableConfigDiscovery: copilot.Bool(false),
		EnableSessionStore:    copilot.Bool(false),
		SystemMessage:         &copilot.SystemMessageConfig{Mode: "append", Content: req.Instructions},
		OnPermissionRequest: func(copilot.PermissionRequest, copilot.PermissionInvocation) (rpc.PermissionDecision, error) {
			return &rpc.PermissionDecisionReject{}, nil
		},
	})
	if err != nil {
		return err
	}
	defer session.Disconnect()
	metadata, err := session.RPC.Tools.GetCurrentMetadata(ctx)
	if err != nil || !toolBridge.validMetadata(metadata) {
		return errors.New("runtime tool surface was not empty")
	}
	if err := toolBridge.authorize(input, "submit"); err != nil {
		return err
	}
	toolBridge.start(input, session.SessionID)
	requestContext, cancel := context.WithCancel(ctx)
	defer cancel()
	unsubscribe := session.On(func(update copilot.SessionEvent) {
		if call, ok := update.Data.(*rpc.ExternalToolRequestedData); ok && !toolBridge.hasTool(call.ToolName) {
			toolBridge.fail()
			return
		}
		if update.AgentID != nil && *update.AgentID != "" {
			return
		}
		var outgoing event
		switch data := update.Data.(type) {
		case *rpc.AssistantMessageDeltaData:
			outgoing = event{Type: "delta", Text: data.DeltaContent}
		case *rpc.AssistantUsageData:
			if data.InputTokens == nil || data.OutputTokens == nil {
				return
			}
			outgoing = event{Type: "usage", Usage: &usage{Input: *data.InputTokens, Output: *data.OutputTokens}}
		default:
			return
		}
		if write(outgoing) != nil {
			cancel()
		}
	})
	defer unsubscribe()
	reply, err := session.SendAndWait(requestContext, copilot.MessageOptions{Prompt: prompt, Attachments: files})
	if err != nil {
		if requestContext.Err() != nil {
			abort, done := context.WithTimeout(context.Background(), 2*time.Second)
			_ = session.Abort(abort)
			done()
		}
		return err
	}
	if reply == nil {
		return errors.New("missing reply")
	}
	answer, ok := reply.Data.(*rpc.AssistantMessageData)
	if !ok || len(answer.ToolRequests) != 0 || (strings.TrimSpace(answer.Content) == "" && !toolBridge.hasPreparedImages()) {
		return errors.New("empty reply")
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return write(event{Type: "completed", Text: answer.Content})
}

func authorize(ctx context.Context, input io.Reader, output *json.Encoder, stage string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := output.Encode(event{Type: stage}); err != nil {
		return err
	}
	var proceed [1]byte
	if _, err := io.ReadFull(input, proceed[:]); err != nil || proceed[0] != 1 {
		return errors.New("request was not authorized to start")
	}
	return ctx.Err()
}

func listModels(ctx context.Context, client *copilot.Client, input io.Reader, output *json.Encoder) error {
	if err := client.Start(ctx); err != nil {
		return err
	}
	auth, err := client.GetAuthStatus(ctx)
	if err != nil {
		return err
	}
	if auth == nil || !auth.IsAuthenticated {
		return errUnauthenticated
	}
	if err := authorize(ctx, input, output, "submit"); err != nil {
		return err
	}
	models, err := client.ListModels(ctx)
	if err != nil {
		return err
	}
	result := make([]catalogModel, 0, len(models))
	seen := make(map[string]bool, len(models))
	for _, model := range models {
		id := strings.TrimSpace(model.ID)
		if id == "" || len(id) > 512 || seen[id] {
			continue
		}
		name := strings.TrimSpace(model.Name)
		if name == "" || len(name) > 512 {
			name = id
		}
		allowed := true
		if model.Policy != nil {
			state := strings.ToLower(strings.TrimSpace(model.Policy.State))
			allowed = state == "" || state == "enabled"
		}
		seen[id] = true
		result = append(result, catalogModel{ID: id, Name: name, Allowed: allowed})
	}
	return output.Encode(event{Type: "models", Models: result})
}

func (file attachment) load(ctx context.Context) (*rpc.AttachmentBlob, error) {
	if !filepath.IsAbs(file.Path) || file.Name == "" || file.MediaType == "" || file.Size < 0 {
		return nil, errors.New("invalid attachment")
	}
	info, err := os.Lstat(file.Path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != file.Size {
		return nil, errors.New("attachment changed")
	}
	source, err := os.Open(file.Path)
	if err != nil {
		return nil, err
	}
	defer source.Close()
	opened, err := source.Stat()
	if err != nil || !os.SameFile(info, opened) || opened.Size() != file.Size {
		return nil, errors.New("attachment changed")
	}

	var data strings.Builder
	encoder := base64.NewEncoder(base64.StdEncoding, &data)
	// Read at most the declared size. A trailing byte indicates concurrent modification.
	reader := attachmentReader{ctx, io.LimitReader(source, file.Size)}
	count, err := io.Copy(encoder, reader)
	if err != nil {
		return nil, err
	}
	var trailing [1]byte
	n, tailErr := source.Read(trailing[:])
	if count != file.Size || n != 0 || tailErr != io.EOF {
		return nil, errors.New("attachment changed")
	}
	if err := encoder.Close(); err != nil {
		return nil, err
	}
	encoded := data.String()
	return &rpc.AttachmentBlob{Data: &encoded, DisplayName: &file.Name, MIMEType: file.MediaType}, nil
}

type attachmentReader struct {
	ctx context.Context
	in  io.Reader
}

func (reader attachmentReader) Read(p []byte) (int, error) {
	if err := reader.ctx.Err(); err != nil {
		return 0, err
	}
	return reader.in.Read(p)
}

func formatPrompt(messages []message) (string, error) {
	last := messages[len(messages)-1]
	if last.Role != "user" {
		return "", errors.New("missing user message")
	}
	if len(messages) == 1 {
		return last.Content, nil
	}
	// The SDK's send method takes a prompt. Keep the app's bounded history
	// separate from both the system instructions and the new user message.
	history, err := json.Marshal(messages[:len(messages)-1])
	if err != nil {
		return "", err
	}
	return "Previous conversation context (JSON, ordered by message):\n" + string(history) +
		"\n\nCurrent user message:\n" + last.Content, nil
}
