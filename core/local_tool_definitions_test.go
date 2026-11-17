package aauvcore

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLocalToolDefinitionsJSON(t *testing.T) {
	result, err := LocalToolDefinitionsJSON(`["read_attachment","search_chat_history"]`)
	if err != nil {
		t.Fatal(err)
	}
	var definitions []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(result), &definitions); err != nil {
		t.Fatal(err)
	}
	if len(definitions) != 2 || string(definitions[0]["name"]) != `"read_attachment"` || len(definitions[0]) != 3 {
		t.Fatal(result)
	}
	if !strings.Contains(string(definitions[1]["parameters"]), `"additionalProperties":false`) {
		t.Fatal(result)
	}
	empty, err := LocalToolDefinitionsJSON(`[]`)
	if err != nil || empty != `[]` {
		t.Fatal(empty, err)
	}
	for _, input := range []string{`null`, `{}`, `["shell"]`, `["create_skill","create_skill"]`, `[1]`, `["read_attachment"] []`, strings.Repeat(" ", 4097)} {
		if _, err := LocalToolDefinitionsJSON(input); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}
