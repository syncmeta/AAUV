package aauvcore

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	authIssuer    = "https://auth.openai.com"
	authResource  = "https://api.openai.com/v1"
	authCallback  = "/auth/callback"
	dynamicClient = "dynamic_agent_client"
)

type ChatGPTSignIn struct {
	authorize string
	redirect  string
	state     string
	nonce     string
	verifier  string
	client    string
	server    *http.Server
	result    chan callbackResult
	once      sync.Once
	timer     *time.Timer
}

type callbackResult struct {
	body string
	err  error
}

func opaqueValue() (string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes[:]), nil
}

// BeginChatGPTSignIn starts an ephemeral listener bound to IPv4 loopback.
func BeginChatGPTSignIn(host, client, idHint string) (*ChatGPTSignIn, error) {
	if !strings.HasPrefix(host, "urn:uuid:") || len(host) != 45 || client == dynamicClient {
		return nil, errors.New("invalid_auth_registration")
	}
	a := &ChatGPTSignIn{client: client, result: make(chan callbackResult, 1)}
	for _, dst := range []*string{&a.state, &a.nonce, &a.verifier} {
		value, err := opaqueValue()
		if err != nil {
			return nil, err
		}
		*dst = value
	}
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("loopback_listener_failed")
	}
	address := listener.Addr().String()
	a.redirect = "http://" + address + authCallback
	digest := sha256.Sum256([]byte(a.verifier))
	query := url.Values{
		"response_type": {"code"}, "redirect_uri": {a.redirect},
		"scope":    {"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"},
		"resource": {authResource}, "ext_agent_host_id": {host},
		"state": {a.state}, "nonce": {a.nonce},
		"code_challenge_method": {"S256"}, "code_challenge": {base64.RawURLEncoding.EncodeToString(digest[:])},
	}
	if client == "" {
		query.Set("client_id", dynamicClient)
		query.Set("agent_name_hint", "AAUV")
	} else {
		query.Set("client_id", client)
		if idHint != "" {
			query.Set("id_token_hint", idHint)
		}
	}
	a.authorize = authIssuer + "/api/accounts/authorize?" + query.Encode()
	a.server = &http.Server{
		ReadHeaderTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second,
		MaxHeaderBytes: 16 * 1024,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Referrer-Policy", "no-referrer")
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			if r.Method != http.MethodGet || r.Host != address || r.URL.Path != authCallback {
				http.Error(w, "Unknown callback", http.StatusNotFound)
				return
			}
			result, valid := a.parseCallback(r.URL.RawQuery)
			if !valid {
				http.Error(w, "Invalid authorization callback", http.StatusBadRequest)
				return
			}
			accepted := false
			a.once.Do(func() {
				accepted = true
				if result.err == nil {
					fmt.Fprint(w, "Authorization returned to AAUV. You can close this page and return to the app.")
				} else {
					fmt.Fprint(w, "Authorization did not complete. Return to AAUV.")
				}
				a.result <- result
				close(a.result)
			})
			if !accepted {
				http.Error(w, "This authorization attempt has ended", http.StatusGone)
			}
		}),
	}
	a.timer = time.AfterFunc(5*time.Minute, func() { a.finish(errors.New("authorization_expired")) })
	go func() {
		if err := a.server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			a.finish(errors.New("loopback_listener_failed"))
		}
	}()
	return a, nil
}

func (a *ChatGPTSignIn) AuthorizationURL() string { return a.authorize }

func (a *ChatGPTSignIn) parseCallback(raw string) (callbackResult, bool) {
	q, err := url.ParseQuery(raw)
	if err != nil || len(q["state"]) != 1 || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(a.state)) != 1 {
		return callbackResult{}, false
	}
	if q.Get("error") != "" {
		return callbackResult{err: errors.New("authorization_declined")}, true
	}
	client := q.Get("client_id")
	if a.client != "" {
		if client != "" && client != a.client {
			return callbackResult{err: errors.New("authorization_client_mismatch")}, true
		}
		client = a.client
	}
	if len(q["client_id"]) > 1 || len(q["code"]) != 1 || q.Get("code") == "" || !strings.HasPrefix(client, "oaiapp_") || len(client) > 256 {
		return callbackResult{err: errors.New("authorization_callback_incomplete")}, true
	}
	form := url.Values{"grant_type": {"authorization_code"}, "client_id": {client}, "code": {q.Get("code")},
		"code_verifier": {a.verifier}, "redirect_uri": {a.redirect}, "resource": {authResource}}
	data, _ := json.Marshal(map[string]string{"client_id": client, "form": form.Encode()})
	return callbackResult{body: string(data)}, true
}

// AwaitCallback blocks until the first valid callback, cancellation, or timeout.
func (a *ChatGPTSignIn) AwaitCallback() (string, error) {
	defer a.timer.Stop()
	result, ok := <-a.result
	if !ok {
		return "", errors.New("authorization_already_read")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = a.server.Shutdown(ctx)
	return result.body, result.err
}

func (a *ChatGPTSignIn) finish(err error) {
	a.once.Do(func() {
		a.result <- callbackResult{err: err}
		close(a.result)
	})
	_ = a.server.Close()
}

func (a *ChatGPTSignIn) Cancel() {
	a.timer.Stop()
	a.finish(errors.New("authorization_cancelled"))
}

type chatGPTIdentity struct {
	Subject string `json:"sub"`
	Email   string `json:"email,omitempty"`
}

func (a *ChatGPTSignIn) VerifyIdentity(token, jwks, client string) (string, error) {
	identity, err := verifyOpenAIIdentity(token, jwks, client, a.nonce, time.Now().Unix())
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(identity)
	return string(data), err
}

func verifyOpenAIIdentity(token, jwks, client, nonce string, now int64) (chatGPTIdentity, error) {
	invalid := errors.New("invalid_chatgpt_identity")
	var identity chatGPTIdentity
	if len(token) > 64*1024 || len(jwks) > 1024*1024 || client == "" || nonce == "" {
		return identity, invalid
	}
	pieces := strings.Split(token, ".")
	if len(pieces) != 3 {
		return identity, invalid
	}
	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	var keys struct {
		Keys []struct {
			Alg string `json:"alg"`
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			Use string `json:"use"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	headerData, err := base64.RawURLEncoding.DecodeString(pieces[0])
	if err != nil || json.Unmarshal(headerData, &header) != nil || header.Alg != "RS256" || header.Kid == "" ||
		json.Unmarshal([]byte(jwks), &keys) != nil {
		return identity, invalid
	}
	var key *rsa.PublicKey
	for _, jwk := range keys.Keys {
		if jwk.Kid != header.Kid || jwk.Kty != "RSA" || (jwk.Alg != "" && jwk.Alg != "RS256") || (jwk.Use != "" && jwk.Use != "sig") {
			continue
		}
		n, nErr := base64.RawURLEncoding.DecodeString(jwk.N)
		e, eErr := base64.RawURLEncoding.DecodeString(jwk.E)
		if nErr != nil || eErr != nil || len(n) > 1024 || len(e) > 4 || key != nil {
			return identity, invalid
		}
		modulus := new(big.Int).SetBytes(n)
		exp := new(big.Int).SetBytes(e).Int64()
		if modulus.BitLen() < 2048 || exp < 3 || exp > 1<<31-1 || exp%2 == 0 {
			return identity, invalid
		}
		key = &rsa.PublicKey{N: modulus, E: int(exp)}
	}
	sig, err := base64.RawURLEncoding.DecodeString(pieces[2])
	digest := sha256.Sum256([]byte(pieces[0] + "." + pieces[1]))
	if err != nil || key == nil || rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig) != nil {
		return identity, invalid
	}
	var claims struct {
		chatGPTIdentity
		Issuer          string          `json:"iss"`
		Audience        json.RawMessage `json:"aud"`
		AuthorizedParty string          `json:"azp"`
		Expires         int64           `json:"exp"`
		NotBefore       int64           `json:"nbf"`
		Nonce           string          `json:"nonce"`
	}
	body, err := base64.RawURLEncoding.DecodeString(pieces[1])
	if err != nil || json.Unmarshal(body, &claims) != nil || claims.Issuer != authIssuer || claims.Expires <= now ||
		claims.NotBefore > now+30 || claims.Subject == "" || subtle.ConstantTimeCompare([]byte(claims.Nonce), []byte(nonce)) != 1 {
		return identity, invalid
	}
	var audiences []string
	if json.Unmarshal(claims.Audience, &audiences) != nil {
		var single string
		if json.Unmarshal(claims.Audience, &single) != nil {
			return identity, invalid
		}
		audiences = []string{single}
	}
	if len(audiences) != 1 || audiences[0] != client || (claims.AuthorizedParty != "" && claims.AuthorizedParty != client) {
		return identity, invalid
	}
	return claims.chatGPTIdentity, nil
}
