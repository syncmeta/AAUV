package aauvcore

import (
	"bytes"
	"encoding/json"
	"errors"
)

// RequestPlanBody extracts the already encoded body from BuildRequest's plan.
// Platform transports must not decode and re-encode opaque reasoning/tool items
// through a floating-point JSON representation before sending the next request.
func RequestPlanBody(planJSON string) ([]byte, error) {
	if len(planJSON) > maxToolRequestBytes+8192 {
		return nil, errors.New("request_too_large")
	}
	var plan requestPlan
	if json.Unmarshal([]byte(planJSON), &plan) != nil {
		return nil, errors.New("invalid_request_plan")
	}
	body := bytes.TrimSpace(plan.Body)
	if len(body) < 2 || body[0] != '{' || body[len(body)-1] != '}' || !json.Valid(body) {
		return nil, errors.New("invalid_request_plan")
	}
	return plan.Body, nil
}
