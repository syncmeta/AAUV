package aauvcore

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

type storeToolSearchTerm struct {
	text   string
	negate bool
}

// This deliberately implements bounded substring expressions, not PostgreSQL
// lexemes/stemming/ranking: whitespace is AND, OR joins groups, - excludes a
// term, and double quotes keep a phrase together. Values are always SQL binds.
func storeToolParseSearch(query string) ([][]storeToolSearchTerm, error) {
	if utf8.RuneCountInString(query) > 1024 || len(query) > 4096 {
		return nil, errors.New("query exceeds 1024 characters or 4096 bytes")
	}
	runes := []rune(query)
	groups := [][]storeToolSearchTerm{{}}
	count := 0
	for i := 0; i < len(runes); {
		for i < len(runes) && unicode.IsSpace(runes[i]) {
			i++
		}
		if i == len(runes) {
			break
		}
		negative := runes[i] == '-'
		if negative {
			i++
			if i == len(runes) || unicode.IsSpace(runes[i]) || runes[i] == '-' {
				return nil, errors.New("'-' must directly precede one word or quoted phrase")
			}
		}
		quoted := runes[i] == '"'
		var word strings.Builder
		if quoted {
			i++
			closed := false
			for i < len(runes) {
				if runes[i] == '"' {
					i++
					closed = true
					break
				}
				if runes[i] == '\\' {
					i++
					if i == len(runes) || (runes[i] != '\\' && runes[i] != '"') {
						return nil, errors.New("quoted phrases only escape double quotes or backslashes")
					}
				}
				word.WriteRune(runes[i])
				i++
			}
			if !closed || strings.TrimSpace(word.String()) == "" {
				return nil, errors.New("quoted phrases must be nonempty and closed")
			}
			if i < len(runes) && !unicode.IsSpace(runes[i]) {
				return nil, errors.New("separate words and quoted phrases with whitespace")
			}
		} else {
			for i < len(runes) && !unicode.IsSpace(runes[i]) {
				if strings.ContainsRune("\"()", runes[i]) {
					return nil, errors.New("use quoted phrases at word boundaries; parentheses are unsupported")
				}
				word.WriteRune(runes[i])
				i++
			}
		}
		value := word.String()
		if !quoted && strings.EqualFold(value, "OR") {
			if negative || len(groups[len(groups)-1]) == 0 {
				return nil, errors.New("OR must have a search term on both sides")
			}
			groups = append(groups, nil)
			continue
		}
		count++
		if count > 32 {
			return nil, errors.New("query exceeds 32 search terms")
		}
		groups[len(groups)-1] = append(groups[len(groups)-1], storeToolSearchTerm{text: value, negate: negative})
	}
	if count == 0 || len(groups[len(groups)-1]) == 0 {
		return nil, errors.New("OR must have a search term on both sides")
	}
	return groups, nil
}

func storeToolSearchSQL(groups [][]storeToolSearchTerm) (string, []string) {
	var alternatives []string
	var arguments []string
	for _, group := range groups {
		var conditions []string
		for _, term := range group {
			condition := "instr(lower(json_extract(payload,'$.content')),lower(?))"
			if term.negate {
				condition += " = 0"
			} else {
				condition += " > 0"
			}
			conditions = append(conditions, condition)
			arguments = append(arguments, term.text)
		}
		alternatives = append(alternatives, "("+strings.Join(conditions, " AND ")+")")
	}
	return "(" + strings.Join(alternatives, " OR ") + ")", arguments
}
