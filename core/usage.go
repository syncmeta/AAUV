package aauvcore

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

const usageSchema = `
CREATE TABLE IF NOT EXISTS model_usage (
 provider TEXT NOT NULL, model TEXT NOT NULL, purpose TEXT NOT NULL,
 requests INTEGER NOT NULL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
 PRIMARY KEY(provider, model, purpose)
);
`

// RecordUsage records reported tokens after a provider response. Raw requests,
// prompts, endpoint URLs, and secrets are not part of this table.
func (s *LocalStore) RecordUsage(provider, model, purpose string, input, output int64) error {
	switch provider {
	case "byok", "chatgpt", "copilot":
	default:
		return errors.New("invalid_usage_provider")
	}
	if strings.TrimSpace(model) == "" || len(model) > 512 || input < 0 || output < 0 || input > 1_000_000_000 || output > 1_000_000_000 {
		return errors.New("invalid_usage_counts")
	}
	switch purpose {
	case "reply", "compression", "title":
	default:
		return errors.New("invalid_usage_purpose")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.run(`INSERT INTO model_usage(provider,model,purpose,requests,input_tokens,output_tokens)
 VALUES(?,?,?,1,?,?) ON CONFLICT(provider,model,purpose) DO UPDATE SET
 requests=requests+1,input_tokens=input_tokens+excluded.input_tokens,output_tokens=output_tokens+excluded.output_tokens`,
		provider, model, purpose, strconv.FormatInt(input, 10), strconv.FormatInt(output, 10))
	return err
}

func (s *LocalStore) Usage() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run(`SELECT json_object('provider',provider,'model',model,'purpose',purpose,
 'requests',requests,'input',input_tokens,'output',output_tokens)
 FROM model_usage ORDER BY requests DESC,provider,model,purpose`)
	if err != nil {
		return "", err
	}
	data := make([]json.RawMessage, 0, len(rows))
	for _, row := range rows {
		data = append(data, json.RawMessage(row))
	}
	result, err := json.Marshal(data)
	return string(result), err
}
