package nativeauth

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/github/copilot-sdk/go/rpc"
)

type fakeTransport struct {
	mu          sync.Mutex
	calls       []string
	begin       func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error)
	advance     func(context.Context, *rpc.AuthLoginAdvanceRequest) (rpc.AuthLoginStep, error)
	cancel      func(context.Context, *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error)
	steps       []rpc.AuthLoginStep
	accounts    []rpc.AccountStatus
	active      *rpc.AccountStatus
	lastCommand rpc.AuthWrite
}

func (f *fakeTransport) record(method string) {
	f.mu.Lock()
	f.calls = append(f.calls, method)
	f.mu.Unlock()
}
func (f *fakeTransport) history() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.calls, ",")
}
func (f *fakeTransport) Begin(ctx context.Context, p *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
	f.record("begin")
	if p.Kind != rpc.LoginProviderKindGitHubDotCom || p.Mode == nil || *p.Mode != rpc.AuthLoginModeSelectAccount {
		panic("wrong provider or implicit account intent")
	}
	if f.begin != nil {
		return f.begin(ctx, p)
	}
	return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: rpc.AuthLoginStepAwaiting{}}, nil
}
func (f *fakeTransport) Advance(ctx context.Context, p *rpc.AuthLoginAdvanceRequest) (rpc.AuthLoginStep, error) {
	f.record("advance")
	if p.FlowID != "opaque-flow" {
		panic("changed opaque flow")
	}
	if f.advance != nil {
		return f.advance(ctx, p)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.steps) == 0 {
		return nil, errors.New("unexpected advance")
	}
	step := f.steps[0]
	f.steps = f.steps[1:]
	return step, nil
}
func (f *fakeTransport) Cancel(ctx context.Context, p *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error) {
	f.record("cancel")
	if p.FlowID != "opaque-flow" {
		panic("wrong flow cancelled")
	}
	if f.cancel != nil {
		return f.cancel(ctx, p)
	}
	return &rpc.SessionAccountsLoginCancelResult{}, nil
}
func (f *fakeTransport) Enumerate(context.Context, *rpc.AccountsEnumerateRequest) (rpc.AuthEnumerateValue, error) {
	f.record("enumerate")
	f.mu.Lock()
	defer f.mu.Unlock()
	return &rpc.AuthEnumerateValueAccounts{Items: append([]rpc.AccountStatus(nil), f.accounts...)}, nil
}
func (f *fakeTransport) Get(context.Context, *rpc.AccountsGetRequest) (rpc.AuthReadValue, error) {
	f.record("get")
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.active == nil {
		return rpc.AuthReadValueActiveAccount{}, nil
	}
	account := *f.active
	return &rpc.AuthReadValueActiveAccount{Account: &account}, nil
}
func (f *fakeTransport) Set(_ context.Context, p *rpc.AccountsSetRequest) (*rpc.AuthWriteResult, error) {
	f.record("set")
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastCommand = p.Command
	switch command := p.Command.(type) {
	case rpc.AuthWriteSwitchActive:
		for _, account := range f.accounts {
			if account.SelectionID == command.SelectionID {
				account.Active = true
				f.active = &account
				return &rpc.AuthWriteResult{Ok: true}, nil
			}
		}
	case rpc.AuthWriteLogout:
		if command.SelectionID != nil && f.active != nil && *command.SelectionID == f.active.SelectionID {
			f.active = nil
			return &rpc.AuthWriteResult{Ok: true}, nil
		}
	}
	return &rpc.AuthWriteResult{Ok: false}, nil
}

func profile(t *testing.T, id string) Profile {
	t.Helper()
	p, err := ProfilePlan(t.TempDir(), id)
	if err != nil {
		t.Fatal(err)
	}
	return p
}
func controller(t *testing.T, f *fakeTransport) *Controller {
	t.Helper()
	c, err := New(profile(t, "profile-a"), f, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return c
}
func pointer[T any](v T) *T { return &v }
func account(id, login string) rpc.AccountStatus {
	return rpc.AccountStatus{Kind: rpc.AccountKindGitHubDotCom, Host: "https://github.com", Login: login, SelectionID: id, Active: true}
}
func completed(login string) rpc.AuthLoginStep {
	return rpc.AuthLoginStepCompleted{Result: rpc.AuthLoginResultDto{Status: rpc.AuthLoginResultStatusCompleted, Host: pointer("https://github.com"), Login: &login}}
}

func TestUserStartedFlowTicketAllowsBoundedContinuation(t *testing.T) {
	a := account("opaque-user", "fixture-user")
	f := &fakeTransport{active: &a, begin: func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
		return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: &rpc.AuthLoginStepOpenURL{URL: "https://github.com/login/oauth/authorize?state=synthetic-only"}}, nil
	}, steps: []rpc.AuthLoginStep{
		rpc.AuthLoginStepAwaiting{},
		rpc.AuthLoginStepCompleted{Result: rpc.AuthLoginResultDto{Status: rpc.AuthLoginResultStatusNeedsAccountSelection,
			Accounts: []rpc.AuthLoginAccount{{Kind: rpc.AccountKindGitHubDotCom, Host: a.Host, Login: a.Login, SelectionID: "choice-opaque"}}}},
		completed(a.Login),
	}}
	c := controller(t, f)
	if f.history() != "" {
		t.Fatal("construction started authentication")
	}
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().State != OpeningURL || f.history() != "begin" {
		t.Fatal(c.Snapshot(), f.history())
	}
	// Observing state does not issue Begin or auto-consent. A UI may use the
	// issued ticket for timer/callback continuation of this same user intent.
	snapshotJSON, _ := json.Marshal(c.Snapshot())
	if strings.Contains(string(snapshotJSON), "synthetic-only") {
		t.Fatal("authorize URL leaked into snapshot JSON")
	}
	_ = c.Export()
	if f.history() != "begin" {
		t.Fatal("observation advanced authentication")
	}
	if err := c.Advance(context.Background(), ticket, nil); err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().State != Awaiting {
		t.Fatal(c.Snapshot())
	}
	if err := c.Advance(context.Background(), ticket, nil); err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().State != Selecting {
		t.Fatal(c.Snapshot())
	}
	if err := c.Advance(context.Background(), ticket, pointer("not-a-choice")); !errors.Is(err, ErrState) {
		t.Fatal(err)
	}
	if err := c.Advance(context.Background(), ticket, pointer("choice-opaque")); err != nil {
		t.Fatal(err)
	}
	view := c.Snapshot()
	if view.State != Completed || view.Identity == nil || view.Identity.SelectionID != a.SelectionID || view.URL != "" {
		t.Fatal(view)
	}
	data, err := json.Marshal(c.Export())
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "opaque") || strings.Contains(string(data), "synthetic-only") || !c.Export().RequiresReauthorization || c.Export().CrossRestartLoginEnabled {
		t.Fatal(string(data))
	}
	if c.Export().Identity.Login != nil || strings.Contains(string(data), a.Login) {
		t.Fatal("default export included private account information")
	}
	private := c.ExportWithPrivateIdentity()
	if private.Identity == nil || private.Identity.Login == nil || *private.Identity.Login != a.Login {
		t.Fatal("explicit private identity export omitted the requested fixture account")
	}
	privateJSON, err := json.Marshal(private)
	if err != nil || strings.Contains(string(privateJSON), "opaque") || !private.RequiresReauthorization || private.CrossRestartLoginEnabled {
		t.Fatal("private identity export contained routing or claimed portable sign-in")
	}
}

func TestPlaintextConsentCannotBeAccepted(t *testing.T) {
	f := &fakeTransport{begin: func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
		return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: rpc.AuthLoginStepCompleted{Result: rpc.AuthLoginResultDto{Status: rpc.AuthLoginResultStatusNeedsPlaintextConsent}}}, nil
	}}
	c := controller(t, f)
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().State != PlaintextBlocked {
		t.Fatal(c.Snapshot())
	}
	if err := c.Advance(context.Background(), ticket, pointer("yes")); !errors.Is(err, ErrPlaintext) {
		t.Fatal(err)
	}
	if f.history() != "begin" {
		t.Fatal("plaintext consent was sent")
	}
	if err := c.CancelFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().State != Cancelled || f.history() != "begin,cancel" {
		t.Fatal(c.Snapshot(), f.history())
	}
}

func TestErrorDeclineUnknownAndUntrustedURL(t *testing.T) {
	for _, test := range []struct {
		name  string
		step  rpc.AuthLoginStep
		state State
		want  error
	}{
		{"error", rpc.AuthLoginStepError{Message: "sensitive-provider-detail"}, Failed, ErrTransport},
		{"declined", rpc.AuthLoginStepCompleted{Result: rpc.AuthLoginResultDto{Status: rpc.AuthLoginResultStatusDeclined}}, Cancelled, nil},
		{"unknown", rpc.RawAuthLoginStepData{}, Failed, ErrResponse},
		{"empty-choice", rpc.AuthLoginStepCompleted{Result: rpc.AuthLoginResultDto{Status: rpc.AuthLoginResultStatusNeedsAccountSelection, Accounts: []rpc.AuthLoginAccount{{}}}}, Failed, ErrResponse},
		{"url", rpc.AuthLoginStepOpenURL{URL: "https://github.com.evil.invalid/authorize"}, Failed, ErrResponse},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := &fakeTransport{begin: func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
				return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: test.step}, nil
			}}
			c := controller(t, f)
			_, err := c.BeginFromUser(context.Background())
			if !errors.Is(err, test.want) || c.Snapshot().State != test.state {
				t.Fatal(err, c.Snapshot())
			}
			data, _ := json.Marshal(c.Snapshot())
			if strings.Contains(string(data), "sensitive-provider-detail") {
				t.Fatal("provider detail leaked")
			}
		})
	}
}

func TestCallAndIntentTimeouts(t *testing.T) {
	f := &fakeTransport{begin: func(ctx context.Context, _ *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	c, err := New(profile(t, "short-timeout"), f, 10*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.BeginFromUser(context.Background()); !errors.Is(err, context.DeadlineExceeded) || c.Snapshot().State != TimedOut {
		t.Fatal(err, c.Snapshot())
	}
	c = controller(t, &fakeTransport{})
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ticket.deadline = time.Now().Add(-time.Second)
	if err := c.Advance(context.Background(), ticket, nil); !errors.Is(err, context.DeadlineExceeded) || c.Snapshot().State != TimedOut {
		t.Fatal(err, c.Snapshot())
	}
}

func TestCancellationAndOldProfileResults(t *testing.T) {
	for _, deactivate := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "deactivate"}[deactivate], func(t *testing.T) {
			started, release := make(chan struct{}), make(chan struct{})
			f := &fakeTransport{begin: func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
				close(started)
				<-release // Intentionally ignores cancellation to emulate a late server reply.
				return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: rpc.AuthLoginStepAwaiting{}}, nil
			}}
			c := controller(t, f)
			result := make(chan error, 1)
			go func() { _, err := c.BeginFromUser(context.Background()); result <- err }()
			<-started
			if deactivate {
				if err := c.DeactivateProfileFromUser(context.Background()); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := c.CancelFromUser(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			other, err := New(profile(t, "profile-b"), &fakeTransport{}, time.Second)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := other.BeginFromUser(context.Background()); err != nil {
				t.Fatal(err)
			}
			close(release)
			if err := <-result; !errors.Is(err, ErrStaleProfile) {
				t.Fatal(err)
			}
			if c.Snapshot().State != Cancelled || c.Snapshot().Busy || other.Snapshot().State != Awaiting || other.Snapshot().ProfileID != "profile-b" {
				t.Fatal(c.Snapshot(), other.Snapshot())
			}
			if f.history() != "begin,cancel" {
				t.Fatal("late old flow was not cleaned up", f.history())
			}
		})
	}
}

func TestTicketsCannotStartOrCrossProfiles(t *testing.T) {
	f := &fakeTransport{}
	c := controller(t, f)
	if err := c.Advance(context.Background(), FlowTicket{}, nil); !errors.Is(err, ErrStaleProfile) {
		t.Fatal(err)
	}
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	other := controller(t, &fakeTransport{})
	_, err = other.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := other.Advance(context.Background(), ticket, nil); !errors.Is(err, ErrStaleProfile) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	untouched := &fakeTransport{}
	fresh := controller(t, untouched)
	if _, err := fresh.BeginFromUser(ctx); !errors.Is(err, context.Canceled) || untouched.history() != "" {
		t.Fatal(err, untouched.history())
	}
}

func TestExplicitRosterSelectionAndLogout(t *testing.T) {
	a, b := account("opaque-a", "fixture-a"), account("opaque-b", "fixture-b")
	f := &fakeTransport{accounts: []rpc.AccountStatus{a, b}}
	c := controller(t, f)
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); !errors.Is(err, ErrState) {
		t.Fatal(err)
	}
	roster, err := c.AccountsFromUser(context.Background())
	if err != nil || len(roster) != 2 {
		t.Fatal(roster, err)
	}
	if err := c.SelectAccountFromUser(context.Background(), b.SelectionID); err != nil {
		t.Fatal(err)
	}
	if c.Snapshot().Identity.Login != b.Login {
		t.Fatal(c.Snapshot())
	}
	if err := c.LogoutFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	command, ok := f.lastCommand.(rpc.AuthWriteLogout)
	if !ok || command.SelectionID == nil || *command.SelectionID != b.SelectionID || c.Snapshot().Identity != nil || c.Snapshot().State != Idle {
		t.Fatal(command, c.Snapshot())
	}
}

func TestPendingLoginAllowsReadOnlyRosterButRequiresCancelBeforeMutation(t *testing.T) {
	a := account("opaque-selected", "selected-user")
	f := &fakeTransport{accounts: []rpc.AccountStatus{a}}
	c := controller(t, f)
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); !errors.Is(err, ErrState) {
		t.Fatal(err)
	}
	if err := c.LogoutFromUser(context.Background()); !errors.Is(err, ErrState) {
		t.Fatal(err)
	}
	if c.Snapshot().State != Awaiting || f.history() != "begin,enumerate" {
		t.Fatal(c.Snapshot(), f.history())
	}
	if err := c.CancelFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); err != nil {
		t.Fatal(err)
	}
	before := f.history()
	if err := c.Advance(context.Background(), ticket, nil); !errors.Is(err, ErrStaleProfile) {
		t.Fatal(err)
	}
	if c.Snapshot().State != Completed || c.Snapshot().Identity.SelectionID != a.SelectionID || f.history() != before {
		t.Fatal(c.Snapshot(), f.history())
	}
}

func TestLateAdvanceCannotOverwriteChoiceMadeAfterCancellation(t *testing.T) {
	a, b := account("opaque-old", "old-user"), account("opaque-new", "new-user")
	started, release := make(chan struct{}), make(chan struct{})
	f := &fakeTransport{accounts: []rpc.AccountStatus{a, b}, advance: func(context.Context, *rpc.AuthLoginAdvanceRequest) (rpc.AuthLoginStep, error) {
		close(started)
		<-release // Deliberately ignore cancellation to simulate a delayed runtime result.
		return completed(a.Login), nil
	}}
	c := controller(t, f)
	ticket, err := c.BeginFromUser(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	late := make(chan error, 1)
	go func() { late <- c.Advance(context.Background(), ticket, nil) }()
	<-started
	if err := c.CancelFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.SelectAccountFromUser(context.Background(), b.SelectionID); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-late; !errors.Is(err, ErrStaleProfile) {
		t.Fatal(err)
	}
	if c.Snapshot().State != Completed || c.Snapshot().Identity.SelectionID != b.SelectionID || c.Snapshot().Busy {
		t.Fatal(c.Snapshot())
	}
}

func TestCancellationMustFinishBeforeIndependentSelection(t *testing.T) {
	a := account("opaque-user", "fixture-user")
	started, release := make(chan struct{}), make(chan struct{})
	f := &fakeTransport{accounts: []rpc.AccountStatus{a}, cancel: func(context.Context, *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error) {
		close(started)
		<-release
		return &rpc.SessionAccountsLoginCancelResult{}, nil
	}}
	c := controller(t, f)
	if _, err := c.BeginFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- c.CancelFromUser(context.Background()) }()
	<-started
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); !errors.Is(err, ErrBusy) {
		t.Fatal(err)
	}
	if f.history() != "begin,enumerate,cancel" {
		t.Fatal(f.history())
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestFailedCancellationKeepsFlowBlockedUntilRetried(t *testing.T) {
	a := account("opaque-user", "fixture-user")
	attempt := 0
	f := &fakeTransport{accounts: []rpc.AccountStatus{a}, cancel: func(context.Context, *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error) {
		attempt++
		if attempt == 1 {
			return nil, errors.New("synthetic cancel failure")
		}
		return &rpc.SessionAccountsLoginCancelResult{}, nil
	}}
	c := controller(t, f)
	if _, err := c.BeginFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.CancelFromUser(context.Background()); !errors.Is(err, ErrTransport) {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); !errors.Is(err, ErrState) {
		t.Fatal(err)
	}
	if err := c.CancelFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := c.AccountsFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.SelectAccountFromUser(context.Background(), a.SelectionID); err != nil {
		t.Fatal(err)
	}
}

func TestDeactivateStillCancelsKnownFlow(t *testing.T) {
	f := &fakeTransport{}
	c := controller(t, f)
	if _, err := c.BeginFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := c.DeactivateProfileFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.history() != "begin,cancel" || c.Snapshot().State != Cancelled || c.Snapshot().Busy {
		t.Fatal(c.Snapshot(), f.history())
	}
	if err := c.CancelFromUser(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.history() != "begin,cancel" {
		t.Fatal("cancelled flow was repeated", f.history())
	}
}

func TestCompletedResultMustMatchRuntimeIdentity(t *testing.T) {
	wrong := account("opaque-wrong", "wrong-user")
	f := &fakeTransport{active: &wrong, begin: func(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
		return &rpc.AuthLoginBegun{FlowID: "opaque-flow", Step: completed("expected-user")}, nil
	}}
	c := controller(t, f)
	if _, err := c.BeginFromUser(context.Background()); !errors.Is(err, ErrResponse) || c.Snapshot().Identity != nil {
		t.Fatal(err, c.Snapshot())
	}
}

func TestProfilePlanAndNoImplicitSDKClient(t *testing.T) {
	root := t.TempDir()
	p, err := ProfilePlan(root, "own-profile")
	if err != nil || p.Directory != filepath.Join(root, "own-profile") || p.RequiredDirectoryMode != 0700 {
		t.Fatal(p, err)
	}
	if _, err := ProfilePlan(root, "../other"); err == nil {
		t.Fatal("path escape")
	}
	if _, err := ProfilePlan("relative", "own-profile"); err == nil {
		t.Fatal("relative directory")
	}
	if _, err := SDKTransportForSession(nil); err == nil {
		t.Fatal("implicit SDK session")
	}
	if _, err := New(p, nil, time.Second); err == nil {
		t.Fatal("implicit transport")
	}
}
