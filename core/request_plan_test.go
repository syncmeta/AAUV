package aauvcore

import (
	"strings"
	"testing"
)

func TestRequestPlanBodyPreservesOpaqueValues(t *testing.T) {
	const body = `{ "input":[{"type":"reasoning","encrypted_content":"opaque","number":9007199254740993,"fraction":0.12345678901234567890123456789}] }`
	plan := `{"url":"https://example.invalid/v1/responses","streaming":true,"body":` + body + `}`
	actual, err := RequestPlanBody(plan)
	if err != nil || string(actual) != body {
		t.Fatalf("opaque body was changed: %s, %v", actual, err)
	}
	for _, invalid := range []string{`{}`, `{"body":null}`, `{"body":[]}`, `{"body":"text"}`, `{"body":{`} {
		if _, err := RequestPlanBody(invalid); err == nil {
			t.Fatal("invalid request plan body accepted")
		}
	}
	if _, err := RequestPlanBody(strings.Repeat(" ", maxToolRequestBytes+8193)); err == nil {
		t.Fatal("oversized request plan accepted")
	}
}
