package aauvcore

import (
	"encoding/json"
	"errors"
	"strings"
)

type botInstructions struct {
	Prompt       *string    `json:"prompt"`
	Skills       *string    `json:"skills"`
	SkillEntries []botSkill `json:"skillEntries,omitempty"`
}

type botSkill struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Markdown string `json:"markdown"`
	Enabled  *bool  `json:"enabled"`
}

func (doc botInstructions) validate() error {
	if doc.Prompt == nil || doc.Skills == nil || len(doc.SkillEntries) > 100 {
		return errors.New("invalid instructions document")
	}
	size := len(*doc.Prompt) + len(*doc.Skills)
	ids := make(map[string]bool, len(doc.SkillEntries))
	for _, skill := range doc.SkillEntries {
		id := strings.ToLower(skill.ID)
		if !validNodeUUID(skill.ID) || ids[id] || skill.Enabled == nil ||
			len(skill.Name) > 240 || strings.TrimSpace(skill.Name) == "" ||
			strings.ContainsAny(skill.Name, "\n\r\u000b\u000c\u0085\u2028\u2029") ||
			strings.TrimSpace(skill.Markdown) == "" {
			return errors.New("invalid skill entry")
		}
		ids[id] = true
		size += len(skill.Name) + len(skill.Markdown)
	}
	if size > 512*1024 {
		return errors.New("instructions too large")
	}
	return nil
}

type botProfile struct {
	ID            string `json:"id"`
	Configuration struct {
		Name            string           `json:"name"`
		Endpoint        string           `json:"endpoint"`
		Model           string           `json:"model"`
		LoginMethod     string           `json:"loginMethod"`
		APIProtocol     string           `json:"apiProtocol,omitempty"`
		HostedTools     []string         `json:"hostedTools,omitempty"`
		ChatGPTClientID string           `json:"chatGPTClientID,omitempty"`
		Instructions    *botInstructions `json:"instructions,omitempty"`
	} `json:"configuration"`
}

func validateBotProfile(payload string) (botProfile, error) {
	var profile botProfile
	decoder := json.NewDecoder(strings.NewReader(payload))
	decoder.DisallowUnknownFields()
	if !json.Valid([]byte(payload)) || decoder.Decode(&profile) != nil ||
		!validNodeUUID(profile.ID) || strings.TrimSpace(profile.Configuration.Name) == "" ||
		(profile.Configuration.LoginMethod != "copilot" && strings.TrimSpace(profile.Configuration.Model) == "") {
		return profile, errors.New("invalid_bot_profile")
	}
	switch profile.Configuration.LoginMethod {
	case "byok", "chatgpt", "copilot":
	default:
		return profile, errors.New("invalid_bot_provider")
	}
	if instructions := profile.Configuration.Instructions; instructions != nil {
		if err := instructions.validate(); err != nil {
			return profile, err
		}
	}
	return profile, nil
}

// Bots returns local and replicated profiles. Their credentials live outside SQLite.
func (s *LocalStore) Bots() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.run("SELECT payload FROM replica WHERE kind='bot' ORDER BY name")
	if err != nil {
		return "", err
	}
	records := make([]json.RawMessage, 0, len(rows))
	for _, row := range rows {
		records = append(records, json.RawMessage(row))
	}
	data, err := json.Marshal(records)
	return string(data), err
}

func (s *LocalStore) SaveBots(payload string) error {
	return s.transaction(true, func() error { return s.saveBots(payload) })
}

func (s *LocalStore) saveBots(payload string) error {
	var records []json.RawMessage
	if err := json.Unmarshal([]byte(payload), &records); err != nil {
		return err
	}
	for _, raw := range records {
		profile, err := validateBotProfile(string(raw))
		if err != nil {
			return err
		}
		name := "b-" + profile.ID
		deleted, err := s.run("SELECT name FROM replica WHERE name=? AND kind='bot_deleted'", name)
		if err != nil {
			return err
		}
		if len(deleted) > 0 {
			return errors.New("bot_was_deleted")
		}
		if err := s.stageRecord(name, "bot", "", string(raw)); err != nil {
			return err
		}
	}
	return nil
}

func (s *LocalStore) DeleteBot(id string) error {
	if !validNodeUUID(id) {
		return errors.New("invalid_bot_profile")
	}
	return s.transaction(true, func() error {
		return s.stageRecord("b-"+id, "bot_deleted", "", "")
	})
}
