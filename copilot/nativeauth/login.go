package nativeauth

import (
	"context"
	"errors"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/github/copilot-sdk/go/rpc"
)

type State string

const (
	Idle             State = "idle"
	OpeningURL       State = "open-url"
	Awaiting         State = "awaiting"
	InputRequired    State = "input-required"
	Selecting        State = "account-selection"
	PlaintextBlocked State = "plaintext-consent-blocked"
	Completed        State = "completed"
	Failed           State = "failed"
	Cancelled        State = "cancelled"
	TimedOut         State = "timed-out"
)

var (
	ErrStaleProfile = errors.New("native_auth_stale_profile")
	ErrBusy         = errors.New("native_auth_busy")
	ErrState        = errors.New("native_auth_invalid_state")
	ErrResponse     = errors.New("native_auth_invalid_response")
	ErrTransport    = errors.New("native_auth_transport_failed")
	ErrPlaintext    = errors.New("native_auth_plaintext_storage_not_approved")
)

// Profile declares a private directory; this prototype does not create or read
// credential stores. The integrating host must create Directory with mode 0700
// and prove the runtime's secret-store isolation before enabling persistence.
type Profile struct {
	ID                    string
	Directory             string
	RequiredDirectoryMode uint32
}

func ProfilePlan(root, id string) (Profile, error) {
	if !filepath.IsAbs(root) || id == "" || len(id) > 128 || strings.Trim(id, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != "" {
		return Profile{}, errors.New("native_auth_invalid_profile")
	}
	return Profile{ID: id, Directory: filepath.Join(root, id), RequiredDirectoryMode: 0700}, nil
}

type Identity struct {
	Kind        rpc.AccountKind `json:"kind"`
	Host        string          `json:"host"`
	Login       string          `json:"login"`
	SelectionID string          `json:"-"` // Opaque runtime-local routing, not portable authorization.
}

// ExportIdentity contains no opaque runtime routing or credential. Login is
// optional private user information and is omitted unless explicitly requested.
type ExportIdentity struct {
	Kind  rpc.AccountKind `json:"kind"`
	Host  string          `json:"host"`
	Login *string         `json:"login,omitempty"`
}

type ExportState struct {
	Mode                     string          `json:"mode"`
	Identity                 *ExportIdentity `json:"identity,omitempty"`
	RequiresReauthorization  bool            `json:"requiresReauthorization"`
	CrossRestartLoginEnabled bool            `json:"crossRestartLoginEnabled"`
}

// Snapshot is UI state and can contain private account names in its identity,
// choices and roster. Hosts must not print this state into ordinary logs.
type Snapshot struct {
	ProfileID string
	State     State
	Busy      bool
	URL       string `json:"-"` // Transient authorize URL; never copied to exports or JSON logs.
	Prompt    string
	Choices   []rpc.AuthLoginAccount
	Accounts  []rpc.AccountStatus
	Identity  *Identity
}

// Controller is bound to one immutable profile and session. There is no default
// transport, automatic polling, browser launch or plaintext-consent acceptance.
type Controller struct {
	mu         sync.Mutex
	profile    Profile
	transport  Transport
	timeout    time.Duration
	active     bool
	epoch      uint64
	flow       string
	cancelling bool
	cancel     context.CancelFunc
	view       Snapshot
}

func New(profile Profile, transport Transport, timeout time.Duration) (*Controller, error) {
	if transport == nil || profile.ID == "" || !filepath.IsAbs(profile.Directory) || profile.RequiredDirectoryMode != 0700 || timeout <= 0 {
		return nil, errors.New("native_auth_profile_and_transport_required")
	}
	return &Controller{profile: profile, transport: transport, timeout: timeout, active: true,
		view: Snapshot{ProfileID: profile.ID, State: Idle}}, nil
}

func (c *Controller) Snapshot() Snapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	view := c.view
	view.Choices = append([]rpc.AuthLoginAccount(nil), view.Choices...)
	view.Accounts = append([]rpc.AccountStatus(nil), view.Accounts...)
	if view.Identity != nil {
		identity := *view.Identity
		view.Identity = &identity
	}
	return view
}

func (c *Controller) Export() ExportState {
	return c.export(false)
}

// ExportWithPrivateIdentity includes the private account name. The host must
// call it only after the user explicitly elects to include that information.
// Neither export path grants portable credentials or cross-restart sign-in.
func (c *Controller) ExportWithPrivateIdentity() ExportState {
	return c.export(true)
}

func (c *Controller) export(includePrivateIdentity bool) ExportState {
	view := c.Snapshot()
	var identity *ExportIdentity
	if view.Identity != nil {
		identity = &ExportIdentity{Kind: view.Identity.Kind, Host: view.Identity.Host}
		if includePrivateIdentity && view.Identity.Login != "" {
			login := view.Identity.Login
			identity.Login = &login
		}
	}
	return ExportState{Mode: "copilot-native", Identity: identity, RequiresReauthorization: true, CrossRestartLoginEnabled: false}
}

// FlowTicket is issued only by BeginFromUser. It grants bounded continuation
// of that one user-started flow, including UI-scheduled polling. It cannot be
// serialized into a reusable login credential or reused by another controller.
type FlowTicket struct {
	owner    *Controller
	epoch    uint64
	flow     string
	deadline time.Time
}

type operation struct {
	ctx    context.Context
	cancel context.CancelFunc
	epoch  uint64
}

func (c *Controller) start(ctx context.Context, ticket *FlowTicket, newFlow bool) (operation, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.active {
		return operation{}, ErrStaleProfile
	}
	if err := ctx.Err(); err != nil {
		return operation{}, err
	}
	if ticket != nil {
		if ticket.owner != c || ticket.epoch != c.epoch || ticket.flow == "" || ticket.flow != c.flow {
			return operation{}, ErrStaleProfile
		}
		if time.Now().After(ticket.deadline) {
			c.view.State, c.view.URL, c.view.Choices = TimedOut, "", nil
			return operation{}, context.DeadlineExceeded
		}
	}
	if c.view.Busy {
		return operation{}, ErrBusy
	}
	if newFlow {
		if c.flow != "" {
			return operation{}, ErrState
		}
		c.epoch++
		c.flow = ""
		c.view = Snapshot{ProfileID: c.profile.ID, State: Idle}
	}
	limit := c.timeout
	if ticket != nil && time.Until(ticket.deadline) < limit {
		limit = time.Until(ticket.deadline)
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	c.cancel = cancel
	c.view.Busy = true
	return operation{ctx, cancel, c.epoch}, nil
}

func (c *Controller) finish(op operation, err error) error {
	if cause := op.ctx.Err(); cause != nil {
		err = cause
	}
	op.cancel()
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.active || c.epoch != op.epoch {
		return ErrStaleProfile
	}
	c.view.Busy = false
	c.cancel = nil
	if err != nil {
		c.view.URL, c.view.Prompt, c.view.Choices = "", "", nil
		switch {
		case errors.Is(err, context.DeadlineExceeded):
			c.view.State = TimedOut
		case errors.Is(err, context.Canceled):
			c.view.State = Cancelled
		default:
			c.view.State = Failed
		}
	}
	return err
}

func callError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return err
	}
	if err != nil {
		return ErrTransport
	} // Do not reflect provider errors/authorize URLs into diagnostics.
	return nil
}

func (c *Controller) BeginFromUser(ctx context.Context) (FlowTicket, error) {
	op, err := c.start(ctx, nil, true)
	if err != nil {
		return FlowTicket{}, err
	}
	mode := rpc.AuthLoginModeSelectAccount
	started, err := c.transport.Begin(op.ctx, &rpc.AuthLoginBeginRequest{Kind: rpc.LoginProviderKindGitHubDotCom, Mode: &mode})
	if err != nil {
		return FlowTicket{}, c.finish(op, callError(err))
	}
	if started == nil || started.FlowID == "" {
		return FlowTicket{}, c.finish(op, ErrResponse)
	}
	c.mu.Lock()
	stale := !c.active || c.epoch != op.epoch
	if !stale {
		c.flow = started.FlowID
	}
	c.mu.Unlock()
	if stale {
		cleanup, cancel := context.WithTimeout(context.Background(), c.timeout)
		_, _ = c.transport.Cancel(cleanup, &rpc.AuthLoginCancelRequest{FlowID: started.FlowID})
		cancel()
		return FlowTicket{}, c.finish(op, ErrStaleProfile)
	}
	err = c.finish(op, c.apply(op, started.Step))
	if err != nil {
		return FlowTicket{}, err
	}
	return FlowTicket{owner: c, epoch: op.epoch, flow: started.FlowID, deadline: time.Now().Add(10 * time.Minute)}, nil
}

// Advance continues only the intent represented by a live ticket. The UI may
// call it on a bounded timer or browser callback; a new click for each awaiting
// poll is not required. Decisions (account/input/consent) still require UI input.
func (c *Controller) Advance(ctx context.Context, ticket FlowTicket, input *string) error {
	op, err := c.start(ctx, &ticket, false)
	if err != nil {
		return err
	}
	c.mu.Lock()
	flow, state, choices := c.flow, c.view.State, append([]rpc.AuthLoginAccount(nil), c.view.Choices...)
	c.mu.Unlock()
	if state == PlaintextBlocked {
		return c.reject(op, ErrPlaintext)
	}
	if flow == "" || (state != OpeningURL && state != Awaiting && state != InputRequired && state != Selecting) {
		return c.reject(op, ErrState)
	}
	if state == Selecting {
		found := false
		for _, choice := range choices {
			if input != nil && choice.SelectionID == *input {
				found = true
			}
		}
		if !found {
			return c.reject(op, ErrState)
		}
	} else if state == InputRequired {
		if input == nil || strings.TrimSpace(*input) == "" || len(*input) > 512 {
			return c.reject(op, ErrState)
		}
	} else if input != nil {
		return c.reject(op, ErrState)
	}
	step, err := c.transport.Advance(op.ctx, &rpc.AuthLoginAdvanceRequest{FlowID: flow, Input: input})
	if err != nil {
		return c.finish(op, callError(err))
	}
	return c.finish(op, c.apply(op, step))
}

func (c *Controller) reject(op operation, err error) error {
	if current := c.finish(op, nil); current != nil {
		return current
	}
	return err
}

func (c *Controller) apply(op operation, step rpc.AuthLoginStep) error {
	if err := op.ctx.Err(); err != nil {
		return err
	}
	view := Snapshot{ProfileID: c.profile.ID}
	switch value := step.(type) {
	case *rpc.AuthLoginStepOpenURL:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case *rpc.AuthLoginStepAwaiting:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case *rpc.AuthLoginStepInputRequired:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case *rpc.AuthLoginStepNeedsInteraction:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case *rpc.AuthLoginStepCompleted:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case *rpc.AuthLoginStepError:
		if value == nil {
			return ErrResponse
		}
		return c.apply(op, *value)
	case rpc.AuthLoginStepOpenURL:
		link, err := url.Parse(value.URL)
		if err != nil || link.Scheme != "https" || link.Host != "github.com" || link.User != nil || link.Fragment != "" {
			return ErrResponse
		}
		view.State, view.URL = OpeningURL, value.URL
	case rpc.AuthLoginStepAwaiting, rpc.AuthLoginStepNeedsInteraction:
		view.State = Awaiting
	case rpc.AuthLoginStepInputRequired:
		view.State, view.Prompt = InputRequired, value.Prompt
	case rpc.AuthLoginStepError:
		return ErrTransport
	case rpc.AuthLoginStepCompleted:
		switch value.Result.Status {
		case rpc.AuthLoginResultStatusNeedsPlaintextConsent:
			view.State = PlaintextBlocked
		case rpc.AuthLoginResultStatusNeedsAccountSelection:
			if len(value.Result.Accounts) == 0 {
				return ErrResponse
			}
			seen := map[string]bool{}
			for _, choice := range value.Result.Accounts {
				if choice.SelectionID == "" || seen[choice.SelectionID] || choice.Login == "" || choice.Kind != rpc.AccountKindGitHubDotCom || choice.Host != "https://github.com" {
					return ErrResponse
				}
				seen[choice.SelectionID] = true
			}
			view.State, view.Choices = Selecting, append([]rpc.AuthLoginAccount(nil), value.Result.Accounts...)
		case rpc.AuthLoginResultStatusDeclined:
			view.State = Cancelled
		case rpc.AuthLoginResultStatusCompleted:
			if value.Result.Host == nil || value.Result.Login == nil {
				return ErrResponse
			}
			identity, err := c.activeIdentity(op.ctx)
			if err != nil {
				return err
			}
			if identity.Host != *value.Result.Host || identity.Login != *value.Result.Login {
				return ErrResponse
			}
			view.State, view.Identity = Completed, &identity
		default:
			return ErrResponse
		}
	default:
		return ErrResponse
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.active || c.epoch != op.epoch {
		return ErrStaleProfile
	}
	view.Busy = true
	view.Accounts = c.view.Accounts
	c.view = view
	if view.State == Completed || view.State == Cancelled {
		// Only a server-confirmed terminal login step retires the runtime flow.
		// A failed/timed-out call still needs explicit cancellation before an
		// unrelated account mutation may replace its authentication intent.
		c.flow = ""
	}
	return nil
}

func (c *Controller) activeIdentity(ctx context.Context) (Identity, error) {
	value, err := c.transport.Get(ctx, &rpc.AccountsGetRequest{Query: rpc.AuthReadQueryActiveAccount{}})
	if err != nil {
		return Identity{}, callError(err)
	}
	var account *rpc.AccountStatus
	switch result := value.(type) {
	case rpc.AuthReadValueActiveAccount:
		account = result.Account
	case *rpc.AuthReadValueActiveAccount:
		if result != nil {
			account = result.Account
		}
	}
	if account == nil || !account.Active || account.Kind != rpc.AccountKindGitHubDotCom || account.Host != "https://github.com" || account.Login == "" || account.SelectionID == "" {
		return Identity{}, ErrResponse
	}
	return Identity{Kind: account.Kind, Host: account.Host, Login: account.Login, SelectionID: account.SelectionID}, nil
}

func (c *Controller) AccountsFromUser(ctx context.Context) ([]rpc.AccountStatus, error) {
	op, err := c.start(ctx, nil, false)
	if err != nil {
		return nil, err
	}
	value, err := c.transport.Enumerate(op.ctx, &rpc.AccountsEnumerateRequest{Query: rpc.AuthEnumerateQueryAccounts{}})
	if err != nil {
		return nil, c.finish(op, callError(err))
	}
	var accounts []rpc.AccountStatus
	switch result := value.(type) {
	case rpc.AuthEnumerateValueAccounts:
		accounts = result.Items
	case *rpc.AuthEnumerateValueAccounts:
		if result == nil {
			return nil, c.finish(op, ErrResponse)
		}
		accounts = result.Items
	default:
		return nil, c.finish(op, ErrResponse)
	}
	c.mu.Lock()
	if c.active && c.epoch == op.epoch {
		c.view.Accounts = append([]rpc.AccountStatus(nil), accounts...)
	}
	c.mu.Unlock()
	if err := c.finish(op, op.ctx.Err()); err != nil {
		return nil, err
	}
	return append([]rpc.AccountStatus(nil), accounts...), nil
}

func (c *Controller) SelectAccountFromUser(ctx context.Context, selectionID string) error {
	op, err := c.start(ctx, nil, false)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.flow != "" {
		c.mu.Unlock()
		return c.reject(op, ErrState)
	}
	var wanted *rpc.AccountStatus
	for _, account := range c.view.Accounts {
		if account.SelectionID == selectionID && selectionID != "" {
			copy := account
			wanted = &copy
		}
	}
	c.mu.Unlock()
	if wanted == nil {
		return c.reject(op, ErrState)
	}
	if wanted.Kind != rpc.AccountKindGitHubDotCom || wanted.Host != "https://github.com" || wanted.Login == "" {
		return c.reject(op, ErrState)
	}
	result, err := c.transport.Set(op.ctx, &rpc.AccountsSetRequest{Command: rpc.AuthWriteSwitchActive{SelectionID: selectionID}})
	if err != nil {
		return c.finish(op, callError(err))
	}
	if result == nil || !result.Ok {
		return c.finish(op, ErrResponse)
	}
	identity, err := c.activeIdentity(op.ctx)
	if err != nil {
		return c.finish(op, err)
	}
	if identity.SelectionID != selectionID || identity.Host != wanted.Host || identity.Login != wanted.Login {
		return c.finish(op, ErrResponse)
	}
	c.mu.Lock()
	if c.active && c.epoch == op.epoch {
		c.view.State, c.view.Identity = Completed, &identity
	}
	c.mu.Unlock()
	return c.finish(op, op.ctx.Err())
}

func (c *Controller) LogoutFromUser(ctx context.Context) error {
	op, err := c.start(ctx, nil, false)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.flow != "" {
		c.mu.Unlock()
		return c.reject(op, ErrState)
	}
	identity := c.view.Identity
	c.mu.Unlock()
	if identity == nil {
		return c.reject(op, ErrState)
	}
	result, err := c.transport.Set(op.ctx, &rpc.AccountsSetRequest{Command: rpc.AuthWriteLogout{SelectionID: &identity.SelectionID}})
	if err != nil {
		return c.finish(op, callError(err))
	}
	if result == nil || !result.Ok {
		return c.finish(op, ErrResponse)
	}
	c.mu.Lock()
	if c.active && c.epoch == op.epoch {
		c.view = Snapshot{ProfileID: c.profile.ID, State: Idle, Busy: true}
		c.flow = ""
	}
	c.mu.Unlock()
	return c.finish(op, op.ctx.Err())
}

// CancelFromUser revokes the current local operation before awaiting the
// runtime's best-effort flow cancellation. Late results cannot update the view.
func (c *Controller) CancelFromUser(ctx context.Context) error {
	c.mu.Lock()
	if c.cancelling {
		c.mu.Unlock()
		return ErrBusy
	}
	if c.cancel != nil {
		c.cancel()
	}
	c.epoch++
	flow := c.flow
	c.view = Snapshot{ProfileID: c.profile.ID, State: Cancelled}
	c.cancel = nil
	if flow != "" {
		c.cancelling = true
		c.view.Busy = true
	}
	c.mu.Unlock()
	if flow == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	_, err := c.transport.Cancel(ctx, &rpc.AuthLoginCancelRequest{FlowID: flow})
	c.mu.Lock()
	c.cancelling = false
	c.view.Busy = false
	if err == nil && c.flow == flow {
		c.flow = ""
	}
	c.mu.Unlock()
	return callError(err)
}

func (c *Controller) DeactivateProfileFromUser(ctx context.Context) error {
	c.mu.Lock()
	c.active = false
	c.mu.Unlock()
	return c.CancelFromUser(ctx)
}
