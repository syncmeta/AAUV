package aauvcore

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

func TestOpenAIIdentityRejectsWrongGrant(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	encode := func(value []byte) string { return base64.RawURLEncoding.EncodeToString(value) }
	jwks, err := json.Marshal(map[string]any{"keys": []map[string]string{{
		"kid": "test-key", "kty": "RSA", "use": "sig", "alg": "RS256", "n": encode(key.N.Bytes()), "e": "AQAB",
	}}})
	if err != nil {
		t.Fatal(err)
	}
	sign := func(issuer, audience, nonce string, expires int64) string {
		t.Helper()
		header := encode([]byte(`{"kid":"test-key","alg":"RS256"}`))
		claims, err := json.Marshal(map[string]any{"iss": issuer, "aud": audience, "nonce": nonce, "exp": expires, "sub": "account-1"})
		if err != nil {
			t.Fatal(err)
		}
		body := header + "." + encode(claims)
		hash := sha256.Sum256([]byte(body))
		sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, hash[:])
		if err != nil {
			t.Fatal(err)
		}
		return body + "." + encode(sig)
	}
	const now = 1000
	good := sign(authIssuer, "oaiapp_1", "nonce", now+60)
	got, err := verifyOpenAIIdentity(good, string(jwks), "oaiapp_1", "nonce", now)
	if err != nil || got.Subject != "account-1" {
		t.Fatal("valid signature was rejected", err)
	}
	parts := strings.Split(good, ".")
	parts[2] = encode(make([]byte, key.Size()))
	for _, wrong := range []string{
		sign(authIssuer, "oaiapp_2", "nonce", now+60),
		sign(authIssuer, "oaiapp_1", "different", now+60),
		sign(authIssuer, "oaiapp_1", "nonce", now),
		sign("https://other.example", "oaiapp_1", "nonce", now+60),
		strings.Join(parts, "."),
	} {
		if _, err := verifyOpenAIIdentity(wrong, string(jwks), "oaiapp_1", "nonce", now); err == nil {
			t.Fatal("invalid identity accepted")
		}
	}
}

func TestAuthorizationCallbackRequiresStateAndMatchingClient(t *testing.T) {
	a := ChatGPTSignIn{state: "expected", client: "oaiapp_existing", verifier: "verifier", redirect: "http://127.0.0.1:3456/auth/callback"}
	for _, query := range []string{"state=wrong&code=secret", "state=expected&state=wrong&code=secret"} {
		if _, valid := a.parseCallback(query); valid {
			t.Fatal("invalid state accepted")
		}
	}
	if result, valid := a.parseCallback("state=expected&code=secret&client_id=oaiapp_different"); !valid || result.err == nil {
		t.Fatal("registration changed on callback")
	}
	result, valid := a.parseCallback("state=expected&code=synthetic")
	if !valid || result.err != nil {
		t.Fatal("returning registration failed")
	}
	var plan map[string]string
	if err := json.Unmarshal([]byte(result.body), &plan); err != nil {
		t.Fatal(err)
	}
	form, err := url.ParseQuery(plan["form"])
	if err != nil || form.Get("redirect_uri") != a.redirect || form.Get("code_verifier") != a.verifier ||
		form.Get("client_id") != a.client || form.Get("code") != "synthetic" {
		t.Fatal("incorrect token exchange")
	}
}

func TestAuthorizationLoopbackSmoke(t *testing.T) {
	if os.Getenv("AAUV_TEST_LOOPBACK") != "1" {
		t.Skip("requires local TCP listen permission")
	}
	const host = "urn:uuid:01234567-89ab-cdef-0123-456789abcdef"
	a, err := BeginChatGPTSignIn(host, "", "")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Cancel()
	authorize, err := url.Parse(a.AuthorizationURL())
	if err != nil {
		t.Fatal(err)
	}
	q := authorize.Query()
	if authorize.Scheme != "https" || authorize.Host != "auth.openai.com" ||
		q.Get("client_id") != "dynamic_agent_client" || q.Get("code_challenge_method") != "S256" {
		t.Fatal("authorization URL is incorrect")
	}
	redirect, err := url.Parse(q.Get("redirect_uri"))
	if err != nil || redirect.Hostname() != "127.0.0.1" || redirect.Path != authCallback {
		t.Fatal("unexpected callback URL")
	}
	client := http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{}}
	request := func(query url.Values) int {
		t.Helper()
		copy := *redirect
		copy.RawQuery = query.Encode()
		response, err := client.Get(copy.String())
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		io.Copy(io.Discard, response.Body)
		return response.StatusCode
	}
	if request(url.Values{"state": {"wrong"}, "code": {"synthetic"}}) != http.StatusBadRequest {
		t.Fatal("wrong state did not fail")
	}
	callback := url.Values{"state": {q.Get("state")}, "client_id": {"oaiapp_synthetic"}, "code": {"synthetic"}}
	if request(callback) != http.StatusOK {
		t.Fatal("valid callback failed")
	}
	if request(callback) != http.StatusGone {
		t.Fatal("callback replay did not fail")
	}
	result, err := a.AwaitCallback()
	if err != nil || !strings.Contains(result, "oaiapp_synthetic") {
		t.Fatal("authorization result was lost")
	}
	if _, err = a.AwaitCallback(); err == nil {
		t.Fatal("authorization result read twice")
	}

	// An expired authorization code can be replaced without a new registration.
	retry, err := BeginChatGPTSignIn(host, "oaiapp_synthetic", "")
	if err != nil {
		t.Fatal(err)
	}
	defer retry.Cancel()
	retryURL, err := url.Parse(retry.AuthorizationURL())
	if err != nil {
		t.Fatal(err)
	}
	next := retryURL.Query()
	if next.Get("client_id") != "oaiapp_synthetic" || next.Get("state") == q.Get("state") ||
		next.Get("nonce") == q.Get("nonce") || next.Get("code_challenge") == q.Get("code_challenge") {
		t.Fatal("reauthorization must reuse only the client registration")
	}
	redirect, err = url.Parse(next.Get("redirect_uri"))
	if err != nil {
		t.Fatal(err)
	}
	if request(url.Values{"state": {next.Get("state")}, "code": {"fresh_code"}}) != http.StatusOK {
		t.Fatal("returning callback without a repeated client ID was rejected")
	}
	result, err = retry.AwaitCallback()
	if err != nil || !strings.Contains(result, "oaiapp_synthetic") {
		t.Fatal("returning authorization lost its client ID")
	}
}
