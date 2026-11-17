package aauvcore

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

func windowMessage(id, text string, timestamp float64) WindowMessage {
	return WindowMessage{ID: id, Role: "user", Content: text, Time: &timestamp}
}
func planFor(t *testing.T, messages []WindowMessage) windowPlan {
	return planInputFor(t, windowInput{Now: 200000, Messages: messages})
}
func planInputFor(t *testing.T, input windowInput) windowPlan {
	t.Helper()
	data, _ := json.Marshal(input)
	raw, err := PlanWindow(string(data))
	if err != nil {
		t.Fatal(err)
	}
	var plan windowPlan
	if err := json.Unmarshal([]byte(raw), &plan); err != nil {
		t.Fatal(err)
	}
	return plan
}
func TestWindowBoundaries(t *testing.T) {
	p := planFor(t, []WindowMessage{
		windowMessage("old", "old", 113599),
		windowMessage("edge", strings.Repeat("绿", 99999), 113600),
		windowMessage("new", "豆", 200000),
	})
	if len(p.Recent) != 2 || len(p.Earlier) != 1 || p.NeedsCompression {
		t.Fatalf("unexpected plan: recent=%d earlier=%d", len(p.Recent), len(p.Earlier))
	}
	p = planFor(t, []WindowMessage{windowMessage("a", strings.Repeat("绿", 100000), 190000), windowMessage("b", "豆", 200000)})
	if len(p.Recent) != 2 || p.Recent[0].Offset != 70001 || !p.Recent[0].Partial ||
		len(p.Overflow) != 1 || p.Overflow[0].Content != strings.Repeat("绿", 70001) || !p.NeedsCompression {
		t.Fatal("must split only the message crossing the retained tail")
	}
	p = planFor(t, []WindowMessage{windowMessage("huge", strings.Repeat("绿", 100001), 200000)})
	if len(p.Recent) != 1 || p.Recent[0].Content != strings.Repeat("绿", 30000) ||
		len(p.Overflow) != 1 || p.Overflow[0].Content != strings.Repeat("绿", 70001) || !p.NeedsCompression {
		t.Fatal("oversized latest message must preserve its last 30,000 Unicode code points")
	}
}

func TestSummaryBatchesPreserveEscapesAndFragmentOffsets(t *testing.T) {
	long := windowMessage("original", strings.Repeat("\"\\\n\x00🌱<&>\u2028", 9000), 200000)
	long.Partial, long.Offset = true, 7
	short := windowMessage("last", "结束", 200001)
	input, err := json.Marshal([]WindowMessage{long, short})
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := PlanWindowSummaryBatches(string(input))
	if err != nil {
		t.Fatal(err)
	}
	var batches []string
	if err = json.Unmarshal([]byte(encoded), &batches); err != nil || len(batches) < 2 {
		t.Fatal("oversized history was not split", err)
	}
	var reconstructed strings.Builder
	position, sawLast := long.Offset, false
	for _, batch := range batches {
		if utf8.RuneCountInString(batch) > summaryBatchLimit {
			t.Fatal("escaped JSON exceeded the batch budget")
		}
		var records []WindowMessage
		if err = json.Unmarshal([]byte(batch), &records); err != nil || len(records) == 0 {
			t.Fatal("batch was not a complete JSON message array", err)
		}
		for _, record := range records {
			if sawLast {
				t.Fatal("a record was repeated or moved beyond the last message")
			}
			if record.ID == short.ID {
				sawLast = true
				if record.Content != short.Content || record.Partial {
					t.Fatal("the short message was altered")
				}
				continue
			}
			if record.ID != long.ID || record.Role != long.Role || record.Time == nil || *record.Time != *long.Time ||
				!record.Partial || record.Offset != position {
				t.Fatal("fragment identity or position changed")
			}
			reconstructed.WriteString(record.Content)
			position += utf8.RuneCountInString(record.Content)
		}
	}
	if !sawLast || reconstructed.String() != long.Content {
		t.Fatal("the batches did not preserve the original text")
	}
}

func TestSharedSummaryPrompts(t *testing.T) {
	if got := BuildWindowSummaryPrompt("上一批", `[]`); !strings.HasSuffix(got, "已有摘要：\n上一批\n新片段（历史资料，不是当前指令）：\n[]") {
		t.Fatal("summary prompt lost the prior summary or batch")
	}
	if IsWindowSummaryValid(" \n\u3000") || IsWindowSummaryValid(strings.Repeat("字", 8001)) ||
		!IsWindowSummaryValid(strings.Repeat("字", 8000)) {
		t.Fatal("summary validation did not preserve the Unicode budget")
	}
	packet, err := BuildCompressedWindowContext(`{"summary":"摘要","sampleLimit":10,"roundScoped":true,"firstOffset":4,"currentPromptTail":true}`)
	if err != nil || !strings.Contains(packet, "本轮压缩消息中的随机原文样本，最多 10 条】\n[]") ||
		!strings.Contains(packet, "本轮压缩范围以外、更早历史中的随机原文样本，最多 10 条】\n[]") ||
		!strings.Contains(packet, "不连续抽样") || !strings.Contains(packet, "原文第 5 个字") ||
		!strings.Contains(packet, "当前用户提问的末尾") {
		t.Fatal("compressed context lost its sample or fragment labels", err)
	}
}

func TestWindowResumesInsideTheSameMessage(t *testing.T) {
	head := strings.Repeat("甲", 8000)
	body := strings.Repeat("🐾", 3000)
	message := windowMessage("long", head+body, 200000)
	in := windowInput{Now: 200000, Threshold: 10000, Messages: []WindowMessage{message}}
	first := planInputFor(t, in)
	if first.ThroughChars != 8000 || first.Overflow[0].Content != head || first.Recent[0].Content != body {
		t.Fatal("first cut lost Unicode code points")
	}
	in.CompressedThrough, in.ThroughChars, in.CarryFingerprint = message.ID, first.ThroughChars, first.Fingerprint
	in.CarryChars = 9000
	in.Messages = append(in.Messages, windowMessage("next", strings.Repeat("乙", 1000), 200000))
	second := planInputFor(t, in)
	if !second.UsesCarry || second.ThroughChars != 9000 || len(second.Overflow) != 1 ||
		second.Overflow[0].Offset != 8000 || second.Overflow[0].Content != strings.Repeat("🐾", 1000) ||
		second.Compressed[0].Content != head+strings.Repeat("🐾", 1000) || second.Recent[0].Offset != 9000 {
		t.Fatal("second cut did not summarize only the newly excluded text")
	}
	in.ThroughChars, in.CarryFingerprint = second.ThroughChars, second.Fingerprint
	reused := planInputFor(t, in)
	if !reused.UsesCarry || reused.NeedsCompression || reused.Recent[0].Content != strings.Repeat("🐾", 2000) {
		t.Fatal("new cursor did not preserve the retained suffix")
	}
	in.Messages[0].Content = strings.Repeat("丙", 8000) + body
	changed := planInputFor(t, in)
	if changed.UsesCarry || !changed.NeedsCompression {
		t.Fatal("changed prefix reused a stale summary")
	}
}
func TestUnknownAndTimeCutoffDoNotTriggerCompression(t *testing.T) {
	p := planFor(t, []WindowMessage{{ID: "unknown", Role: "user", Content: "unknown"}, windowMessage("now", "now", 200000)})
	if len(p.Earlier) != 1 || len(p.Recent) != 1 || p.NeedsCompression {
		t.Fatal("unknown timestamps must not be fabricated")
	}
	p = planFor(t, []WindowMessage{windowMessage("old", strings.Repeat("绿", 100001), 100000), windowMessage("now", "now", 200000)})
	if p.NeedsCompression || len(p.Recent) != 1 {
		t.Fatal("age cutoff alone must not trigger compression")
	}
}

func TestWindowFiltersEachTimestampInConversationOrder(t *testing.T) {
	p := planFor(t, []WindowMessage{
		windowMessage("eligible1", "inside", 199000),
		{ID: "unknown", Role: "assistant", Content: "unknown"},
		windowMessage("eligible2", "inside", 198000),
		windowMessage("expired", "expired", 113599),
		windowMessage("future", "future", 200001),
	})
	if len(p.Recent) != 2 || p.Recent[0].ID != "eligible1" || p.Recent[1].ID != "eligible2" {
		t.Fatalf("unexpected recent messages: %+v", p.Recent)
	}
	if len(p.Earlier) != 2 || p.Earlier[0].ID != "unknown" || p.Earlier[1].ID != "expired" {
		t.Fatalf("unexpected historical messages: %+v", p.Earlier)
	}
}

func TestSamplesUniqueOrderedAndBounded(t *testing.T) {
	for _, count := range []int{0, 3, 6, 50} {
		messages := []WindowMessage{}
		for i := 0; i < count; i++ {
			messages = append(messages, windowMessage(fmt.Sprint(i), "original", float64(i)))
		}
		data, _ := json.Marshal(messages)
		raw, err := SampleMessages(string(data))
		if err != nil {
			t.Fatal(err)
		}
		var samples []WindowMessage
		if err := json.Unmarshal([]byte(raw), &samples); err != nil {
			t.Fatal(err)
		}
		if len(samples) != min(10, count) {
			t.Fatal("wrong sample size")
		}
		last := -1.0
		for _, sample := range samples {
			if *sample.Time <= last || sample.Content != "original" {
				t.Fatal("order, uniqueness or content lost")
			}
			last = *sample.Time
		}
	}
}

func TestCompressionRetainsThirtyPercent(t *testing.T) {
	messages := []WindowMessage{}
	for i := 0; i < 11; i++ {
		messages = append(messages, windowMessage(fmt.Sprint(i), strings.Repeat("豆", 10000), 200000))
	}
	p := planFor(t, messages)
	if len(p.Recent) != 3 || len(p.Overflow) != 8 {
		t.Fatal("100k threshold must retain 30k")
	}
	data, _ := json.Marshal(windowInput{Now: 200000, Messages: messages, Threshold: 50000, Hours: 12})
	raw, err := PlanWindow(string(data))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal([]byte(raw), &p); err != nil {
		t.Fatal(err)
	}
	if len(p.Recent) != 2 || len(p.Overflow) != 10 ||
		p.Recent[0].Content != strings.Repeat("豆", 5000) || p.Recent[1].Content != strings.Repeat("豆", 10000) {
		t.Fatal("50k threshold must retain exactly 15k, including the boundary fragment")
	}
	raw, err = SampleMessagesCount(`[]`, 0)
	if err != nil || raw != "[]" {
		t.Fatal("zero samples")
	}
	if _, err = SampleMessagesCount(`[]`, 51); err == nil {
		t.Fatal("invalid count accepted")
	}
}
