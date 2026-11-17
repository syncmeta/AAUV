package aauvcore

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"unicode/utf8"
)

// WindowMessage keeps original identity, order, speaker and source time.
// An absent timestamp is unknown, not implicitly the current time.
type WindowMessage struct {
	ID      string   `json:"id"`
	Role    string   `json:"role"`
	Content string   `json:"content"`
	Time    *float64 `json:"time,omitempty"`
	Partial bool     `json:"partial,omitempty"`
	Offset  int      `json:"offset,omitempty"`
}

type windowInput struct {
	Now               float64         `json:"now"`
	Messages          []WindowMessage `json:"messages"`
	Threshold         int             `json:"threshold"`
	Hours             int             `json:"hours"`
	CompressedThrough string          `json:"compressed_through"`
	ThroughChars      int             `json:"through_chars"`
	CarryFingerprint  string          `json:"carry_fingerprint"`
	CarryChars        int             `json:"carry_chars"`
}

type windowPlan struct {
	Recent           []WindowMessage `json:"recent"`
	Overflow         []WindowMessage `json:"overflow"`
	Earlier          []WindowMessage `json:"earlier"`
	Compressed       []WindowMessage `json:"compressed"`
	Fingerprint      string          `json:"compression_fingerprint,omitempty"`
	ThroughChars     int             `json:"through_chars,omitempty"`
	UsesCarry        bool            `json:"uses_carry"`
	NeedsCompression bool            `json:"needs_compression"`
}

// PlanWindow partitions a single conversation in original order. Recent messages
// must fall within the time horizon; crossing the threshold reduces raw history to 30%.
// Only the message crossing the retention boundary is split. The original is
// left intact and a cursor records how many of its code points were compressed.
func PlanWindow(input string) (string, error) {
	var in windowInput
	if err := json.Unmarshal([]byte(input), &in); err != nil {
		return "", err
	}
	if in.Now <= 0 {
		return "", errors.New("invalid_request_time")
	}
	if in.Threshold == 0 {
		in.Threshold = 100000
	}
	if in.Hours == 0 {
		in.Hours = 24
	}
	if in.Threshold < 10000 || in.Threshold > 200000 || in.Hours < 1 || in.Hours > 168 || in.CarryChars < 0 || in.ThroughChars < 0 {
		return "", errors.New("invalid_window_settings")
	}
	seen := map[string]bool{}
	eligible := make([]WindowMessage, 0, len(in.Messages))
	earlier := []WindowMessage{}
	cutoff := in.Now - float64(in.Hours*3600)
	for _, m := range in.Messages {
		if m.ID == "" || seen[m.ID] {
			return "", errors.New("invalid_message_identity")
		}
		seen[m.ID] = true
		if m.Role != "user" && m.Role != "assistant" {
			return "", errors.New("invalid_message_role")
		}
		if m.Partial || m.Offset != 0 {
			return "", errors.New("window_requires_original_messages")
		}
		if m.Time == nil || *m.Time < cutoff {
			earlier = append(earlier, m)
		} else if *m.Time <= in.Now {
			eligible = append(eligible, m)
		}
	}
	rawStart, total := 0, 0
	covered, raw := eligible[:0], eligible
	if in.CompressedThrough != "" {
		for i, message := range eligible {
			if message.ID != in.CompressedThrough {
				continue
			}
			index := i + 1
			if in.ThroughChars > 0 {
				if in.ThroughChars >= utf8.RuneCountInString(message.Content) {
					break
				}
				index = i
			}
			prefix, suffix := splitWindow(eligible, index, in.ThroughChars)
			if in.CarryFingerprint != "" {
				fingerprint, err := windowFingerprint(prefix)
				if err != nil {
					return "", err
				}
				if fingerprint != in.CarryFingerprint {
					break
				}
			}
			rawStart = index
			covered, raw = prefix, suffix
			total = min(in.CarryChars, in.Threshold+1)
			break
		}
	}
	for _, m := range raw {
		total += utf8.RuneCountInString(m.Content)
		if total > in.Threshold {
			break
		}
	}
	overflow, recent := raw[:0], raw
	throughChars := 0
	if total > in.Threshold {
		index, offset := retentionBoundary(raw, in.Threshold*3/10)
		overflow, recent = splitWindow(raw, index, offset)
		if offset > 0 {
			throughChars = raw[index].Offset + offset
		}
	}
	result := windowPlan{
		Recent: recent, Overflow: overflow, Earlier: earlier, Compressed: covered,
		UsesCarry: len(covered) > 0, NeedsCompression: len(overflow) > 0,
	}
	if result.NeedsCompression {
		// Rebuild the cumulative prefix directly from originals. This also joins
		// adjacent fragments of the same message when a cursor moves within it.
		index := rawStart + len(overflow)
		if throughChars > 0 {
			index--
		}
		result.Compressed, _ = splitWindow(eligible, index, throughChars)
		fingerprint, err := windowFingerprint(result.Compressed)
		if err != nil {
			return "", err
		}
		result.Fingerprint = fingerprint
		result.ThroughChars = throughChars
	}
	data, err := json.Marshal(result)
	return string(data), err
}

func retentionBoundary(messages []WindowMessage, limit int) (index, offset int) {
	for i := len(messages) - 1; i >= 0; i-- {
		size := utf8.RuneCountInString(messages[i].Content)
		if size > limit {
			if limit == 0 {
				return i + 1, 0
			}
			return i, size - limit
		}
		limit -= size
	}
	return 0, 0
}

func splitWindow(messages []WindowMessage, index, offset int) ([]WindowMessage, []WindowMessage) {
	if offset == 0 {
		return messages[:index], messages[index:]
	}
	head, tail := messages[index], messages[index]
	cut := scalarByteIndex(head.Content, offset)
	head.Content, tail.Content = head.Content[:cut], tail.Content[cut:]
	head.Partial, tail.Partial = true, true
	tail.Offset += offset
	prefix := append(append([]WindowMessage(nil), messages[:index]...), head)
	suffix := append([]WindowMessage{tail}, messages[index+1:]...)
	return prefix, suffix
}

func scalarByteIndex(content string, count int) int {
	for index := range content {
		if count == 0 {
			return index
		}
		count--
	}
	return len(content)
}

func windowFingerprint(messages []WindowMessage) (string, error) {
	hash := sha256.New()
	encoder := json.NewEncoder(hash)
	for _, message := range messages {
		if err := encoder.Encode(message); err != nil {
			return "", err
		}
	}
	return "window2:" + hex.EncodeToString(hash.Sum(nil)), nil
}

// SampleMessages samples without replacement, then restores source order.
// Sampled messages are evidence excerpts, never a continuous dialogue.
func SampleMessages(input string) (string, error) {
	return SampleMessagesCount(input, 10)
}

func SampleMessagesCount(input string, count int) (string, error) {
	if count < 0 || count > 50 {
		return "", errors.New("invalid_sample_count")
	}
	var messages []WindowMessage
	if err := json.Unmarshal([]byte(input), &messages); err != nil {
		return "", err
	}
	indices := make([]int, len(messages))
	for i := range indices {
		indices[i] = i
	}
	n := min(count, len(indices))
	chosen := map[int]bool{}
	for i := 0; i < n; i++ {
		value, err := rand.Int(rand.Reader, big.NewInt(int64(len(indices)-i)))
		if err != nil {
			return "", err
		}
		j := i + int(value.Int64())
		indices[i], indices[j] = indices[j], indices[i]
		chosen[indices[i]] = true
	}
	result := []WindowMessage{}
	for i, m := range messages {
		if chosen[i] {
			result = append(result, m)
		}
	}
	data, err := json.Marshal(result)
	return string(data), err
}
