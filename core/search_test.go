package aauvcore

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

func TestSearchHistory(t *testing.T) {
	db, err := OpenLocalStore(filepath.Join(t.TempDir(), "history.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	payload := fmt.Sprintf(`[
		{"id":"first","title":"旅行计划","bot":{"name":"Atlas"},
		 "attachments":[{"name":"%s"}],
		 "messages":[{"id":"body","role":"user","date":712345678,
		              "content":"%s关键词%%_末尾"},
		             {"id":"file","role":"assistant","content":"完成","attachments":[{"name":"地图.pdf"}]}]},
		{"id":"second","title":"其他","messages":[{"id":"other","role":"user","content":"关键词"}]}
	]`, "行程.txt", strings.Repeat("前", 210))
	if err := db.Insert(payload, true); err != nil {
		t.Fatal(err)
	}
	search := func(text, scope, cursor string) historyPage {
		t.Helper()
		raw, err := db.SearchHistory(text, scope, cursor)
		if err != nil {
			t.Fatal(err)
		}
		var page historyPage
		if err := json.Unmarshal([]byte(raw), &page); err != nil {
			t.Fatal(err)
		}
		return page
	}
	for _, text := range []string{"旅行", "atlas", "行程.TXT"} {
		hits := search(text, "", "").Hits
		if len(hits) != 1 || hits[0].ConversationID != "first" || hits[0].MessageID != "" {
			t.Fatalf("unexpected conversation hits for %q: %+v", text, hits)
		}
	}
	hits := search(" 关键词 ", "first", "").Hits
	if len(hits) != 1 || hits[0].MessageID != "body" || hits[0].Date == nil || *hits[0].Date != 712345678 ||
		!strings.HasPrefix(hits[0].Preview, "…") || !strings.Contains(hits[0].Preview, "关键词") {
		t.Fatalf("expected a snippet near the match: %+v", hits)
	}
	hits = search("地图", "", "").Hits
	if len(hits) != 1 || hits[0].MessageID != "file" || hits[0].Attachment != "地图.pdf" {
		t.Fatalf("expected an attachment-name match: %+v", hits)
	}
	if len(search("%_", "", "").Hits) != 1 || len(search("关键词", "", "").Hits) != 2 {
		t.Fatal("search did not treat SQL metacharacters literally or scope all chats")
	}
	if err := db.Delete("first"); err != nil {
		t.Fatal(err)
	}
	if len(search("地图", "", "").Hits) != 0 || len(search("关键词", "first", "").Hits) != 0 {
		t.Fatal("search returned deleted records")
	}
}

func TestSearchHistoryPaginatesAcrossConversationAndMessageResults(t *testing.T) {
	db, err := OpenLocalStore(filepath.Join(t.TempDir(), "history.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var rows []string
	for i := 1; i <= 100; i++ {
		rows = append(rows, fmt.Sprintf(`{"id":"c%d","title":"match","messages":[{"id":"m%d","content":"match","role":"user"}]}`, i, i))
	}
	if err := db.Insert("["+strings.Join(rows, ",")+"]", false); err != nil {
		t.Fatal(err)
	}
	cursor := ""
	for pageNum := 0; pageNum < 4; pageNum++ {
		raw, err := db.SearchHistory("match", "", cursor)
		if err != nil {
			t.Fatal(err)
		}
		var page historyPage
		if err := json.Unmarshal([]byte(raw), &page); err != nil {
			t.Fatal(err)
		}
		if len(page.Hits) != historyPageSize || (page.NextCursor == "") != (pageNum == 3) {
			t.Fatalf("unexpected page size or cursor for page %d", pageNum)
		}
		for i, hit := range page.Hits {
			n := 1 + pageNum%2*historyPageSize + i
			wantMessage := ""
			if pageNum >= 2 {
				wantMessage = fmt.Sprintf("m%d", n)
			}
			if hit.ConversationID != fmt.Sprintf("c%d", n) || hit.MessageID != wantMessage {
				t.Fatalf("unexpected hit on page %d: %+v", pageNum, hit)
			}
		}
		cursor = page.NextCursor
	}
	if _, err := db.SearchHistory("match", "", "m:-1"); err == nil {
		t.Fatal("invalid cursor accepted")
	}
}
