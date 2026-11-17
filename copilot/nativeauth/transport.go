// Package nativeauth is an experimental backend component using the public
// experimental account API of the pinned Copilot SDK v1.0.28. It is not an
// enabled application login path and never starts a client or runtime itself.
// The integrating host must prove profile isolation and secure credential
// storage before enabling persistent native sign-in.
package nativeauth

import (
	"context"
	"errors"

	copilot "github.com/github/copilot-sdk/go"
	"github.com/github/copilot-sdk/go/rpc"
)

// Transport belongs to exactly one app-owned profile and runtime session.
// Implementations must respect context cancellation. Tests inject only fakes.
type Transport interface {
	Begin(context.Context, *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error)
	Advance(context.Context, *rpc.AuthLoginAdvanceRequest) (rpc.AuthLoginStep, error)
	Cancel(context.Context, *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error)
	Enumerate(context.Context, *rpc.AccountsEnumerateRequest) (rpc.AuthEnumerateValue, error)
	Get(context.Context, *rpc.AccountsGetRequest) (rpc.AuthReadValue, error)
	Set(context.Context, *rpc.AccountsSetRequest) (*rpc.AuthWriteResult, error)
}

type sdkTransport struct{ session *copilot.Session }

// SDKTransportForSession adapts an explicitly supplied, already-isolated SDK
// session. The caller owns its private HOME/BaseDirectory and runtime lifetime.
// Merely constructing the adapter does not invoke any SDK account operation.
func SDKTransportForSession(session *copilot.Session) (Transport, error) {
	if session == nil || session.RPC == nil || session.RPC.Accounts == nil {
		return nil, errors.New("native_auth_session_required")
	}
	return sdkTransport{session}, nil
}

func (s sdkTransport) Begin(ctx context.Context, p *rpc.AuthLoginBeginRequest) (*rpc.AuthLoginBegun, error) {
	return s.session.RPC.Accounts.Login().Begin(ctx, p)
}
func (s sdkTransport) Advance(ctx context.Context, p *rpc.AuthLoginAdvanceRequest) (rpc.AuthLoginStep, error) {
	return s.session.RPC.Accounts.Login().Advance(ctx, p)
}
func (s sdkTransport) Cancel(ctx context.Context, p *rpc.AuthLoginCancelRequest) (*rpc.SessionAccountsLoginCancelResult, error) {
	return s.session.RPC.Accounts.Login().Cancel(ctx, p)
}
func (s sdkTransport) Enumerate(ctx context.Context, p *rpc.AccountsEnumerateRequest) (rpc.AuthEnumerateValue, error) {
	return s.session.RPC.Accounts.Enumerate(ctx, p)
}
func (s sdkTransport) Get(ctx context.Context, p *rpc.AccountsGetRequest) (rpc.AuthReadValue, error) {
	return s.session.RPC.Accounts.Get(ctx, p)
}
func (s sdkTransport) Set(ctx context.Context, p *rpc.AccountsSetRequest) (*rpc.AuthWriteResult, error) {
	return s.session.RPC.Accounts.Set(ctx, p)
}
