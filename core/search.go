package aauvcore

import (
	"encoding/json"
	"errors"
	"math"
	"strconv"
	"strings"
	"unicode/utf8"
)

const historyPageSize = 50

type historyHit struct {
	Ordering       int64    `json:"ordering"`
	ConversationID string   `json:"conversationID"`
	MessageID      string   `json:"messageID,omitempty"`
	Title          string   `json:"title"`
	BotName        string   `json:"botName,omitempty"`
	Role           string   `json:"role,omitempty"`
	Date           *float64 `json:"date,omitempty"`
	Preview        string   `json:"preview,omitempty"`
	Attachment     string   `json:"attachment,omitempty"`
}

type historyPage struct {
	Hits       []historyHit `json:"hits"`
	NextCursor string       `json:"nextCursor,omitempty"`
}

// SearchHistory returns literal substring matches without duplicating the store's
// content. Conversation matches precede messages; each group uses a keyset cursor.
func (s *LocalStore) SearchHistory(query, conversationID, cursor string) (string, error) {
	query = strings.TrimSpace(query)
	page := historyPage{Hits: []historyHit{}}
	if query == "" {
		return `{"hits":[]}`, nil
	}
	if utf8.RuneCountInString(query) > 256 {
		return "", errors.New("history_search_query_too_long")
	}
	kind, before := "c", int64(math.MaxInt64)
	if cursor != "" {
		var order string
		kind, order, _ = strings.Cut(cursor, ":")
		var err error
		before, err = strconv.ParseInt(order, 10, 64)
		if err != nil || before < 0 || (kind != "c" && kind != "m") {
			return "", errors.New("invalid_history_search_cursor")
		}
	}

	err := s.transaction(false, func() error {
		if kind == "c" {
			rows, err := s.run(searchConversations, query, strconv.FormatInt(before, 10), conversationID, strconv.Itoa(historyPageSize+1))
			if err != nil {
				return err
			}
			if err := page.appendRows(rows); err != nil {
				return err
			}
			if len(page.Hits) > historyPageSize {
				page.truncate("c")
				return nil
			}
			before = math.MaxInt64
		}
		conversationMatches := len(page.Hits)
		limit := strconv.Itoa(historyPageSize + 1 - conversationMatches)
		rows, err := s.run(searchMessages, query, strconv.FormatInt(before, 10), conversationID, limit)
		if err != nil {
			return err
		}
		if err := page.appendRows(rows); err != nil {
			return err
		}
		if len(page.Hits) > historyPageSize {
			if conversationMatches == historyPageSize {
				page.NextCursor = "m:" + strconv.FormatInt(math.MaxInt64, 10)
				page.Hits = page.Hits[:historyPageSize]
			} else {
				page.truncate("m")
			}
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	encoded, err := json.Marshal(page)
	return string(encoded), err
}

func (p *historyPage) appendRows(rows []string) error {
	for _, row := range rows {
		var hit historyHit
		if err := json.Unmarshal([]byte(row), &hit); err != nil {
			return err
		}
		p.Hits = append(p.Hits, hit)
	}
	return nil
}

func (p *historyPage) truncate(kind string) {
	p.Hits = p.Hits[:historyPageSize]
	p.NextCursor = kind + ":" + strconv.FormatInt(p.Hits[historyPageSize-1].Ordering-1, 10)
}

const searchConversations = `
WITH candidates AS (
	SELECT ordering, id, coalesce(json_extract(header,'$.title'),'') AS title,
		json_extract(header,'$.bot.name') AS botName,
		(SELECT json_extract(value,'$.name') FROM json_each(header,'$.attachments')
		 WHERE instr(lower(json_extract(value,'$.name')),lower(?1)) > 0 LIMIT 1) AS attachment
	FROM conversation WHERE ordering <= CAST(?2 AS INTEGER) AND (?3 = '' OR id = ?3)
)
SELECT json_object('ordering',ordering,'conversationID',id,'title',title,
	'botName',botName,'attachment',attachment)
FROM candidates
WHERE instr(lower(title),lower(?1)) > 0 OR instr(lower(botName),lower(?1)) > 0 OR attachment IS NOT NULL
ORDER BY ordering DESC LIMIT CAST(?4 AS INTEGER)
`

const searchMessages = `
WITH candidates AS (
	SELECT m.ordering, m.conversation_id, m.id, m.payload, c.header,
		coalesce(json_extract(m.payload,'$.content'),'') AS content,
		(SELECT json_extract(value,'$.name') FROM json_each(m.payload,'$.attachments')
		 WHERE instr(lower(json_extract(value,'$.name')),lower(?1)) > 0 LIMIT 1) AS attachment
	FROM message m JOIN conversation c ON c.id = m.conversation_id
	WHERE m.ordering <= CAST(?2 AS INTEGER) AND (?3 = '' OR m.conversation_id = ?3)
), matches AS (
	SELECT *, instr(lower(content),lower(?1)) AS position FROM candidates
)
SELECT json_object('ordering',ordering,'conversationID',conversation_id,'messageID',id,
	'title',coalesce(json_extract(header,'$.title'),''),
	'botName',json_extract(header,'$.bot.name'),'role',json_extract(payload,'$.role'),
	'date',json_extract(payload,'$.date'),'attachment',attachment,
	'preview',(CASE WHEN position > 55 THEN '…' ELSE '' END)
		|| substr(content,max(1,position-54),180)
		|| (CASE WHEN length(content) >= max(1,position-54)+180 THEN '…' ELSE '' END))
FROM matches WHERE position > 0 OR attachment IS NOT NULL
ORDER BY ordering DESC LIMIT CAST(?4 AS INTEGER)
`
