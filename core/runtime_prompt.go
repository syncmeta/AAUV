package aauvcore

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
	_ "time/tzdata"
	"unicode/utf8"
)

type runtimePromptInput struct {
	BotName       string                 `json:"botName"`
	TimeZone      string                 `json:"timeZone"`
	OffsetSeconds int                    `json:"offsetSeconds"`
	Now           float64                `json:"now"`
	Messages      []runtimePromptMessage `json:"messages"`
}

type runtimePromptMessage struct {
	ID       string   `json:"id"`
	Role     string   `json:"role"`
	Content  string   `json:"content"`
	Time     *float64 `json:"time,omitempty"`
	Original bool     `json:"original"`
}

type runtimePromptOutput struct {
	Instructions string                 `json:"instructions"`
	TimeZone     string                 `json:"timeZone"`
	Messages     []runtimePromptMessage `json:"messages"`
}

// RenderRuntimeContext supplies model-only identity and time context. Message
// time is Unix seconds. Original=false leaves generated memory packets alone;
// summaries, delegation and attachment readers need not call this function.
// Persist the original messages, never these rendered copies.
func RenderRuntimeContext(input string) (string, error) {
	if len(input) > 64*1024*1024 {
		return "", errors.New("runtime context is too large")
	}
	var request *runtimePromptInput
	if err := json.Unmarshal([]byte(input), &request); err != nil || request == nil {
		return "", errors.New("invalid runtime context")
	}
	name := strings.TrimSpace(request.BotName)
	if utf8.RuneCountInString(name) > 512 || len(request.TimeZone) > 128 ||
		request.OffsetSeconds < -86400 || request.OffsetSeconds > 86400 {
		return "", errors.New("invalid runtime context settings")
	}
	now, ok := runtimePromptTime(request.Now)
	if !ok {
		return "", errors.New("invalid runtime context time")
	}
	location, err := time.LoadLocation(request.TimeZone)
	if err != nil || request.TimeZone == "Local" {
		offset := time.FixedZone("", request.OffsetSeconds)
		label := "UTC" + now.In(offset).Format("-07:00")
		location = time.FixedZone(label, request.OffsetSeconds)
	}
	sections := make([]string, 0, 2)
	if name != "" {
		sections = append(sections, "## 你的名字\n你叫「"+name+"」。这是用户给你起的名字，别人也用这个名字称呼你。")
	}
	sections = append(sections, "## 请求时间\n本次请求开始于 "+runtimePromptStamp(now, location)+"。用户消息末尾的系统时间提示仅用于理解时间，不要模仿该格式输出。")
	if request.Messages == nil {
		request.Messages = []runtimePromptMessage{}
	}
	for index := range request.Messages {
		message := &request.Messages[index]
		if message.Role != "user" && message.Role != "assistant" {
			return "", errors.New("invalid runtime message role")
		}
		if message.Role != "user" || !message.Original || message.Time == nil {
			continue
		}
		sent, valid := runtimePromptTime(*message.Time)
		if !valid {
			continue // Unknown legacy dates must not be invented.
		}
		message.Content += "\n（系统提示：此消息发送于 " + runtimePromptStamp(sent, location) + "。此提示用户不可见，你也**不要**模仿此格式输出）"
	}
	data, err := json.Marshal(runtimePromptOutput{Instructions: strings.Join(sections, "\n\n"),
		TimeZone: location.String(), Messages: request.Messages})
	return string(data), err
}

func runtimePromptTime(value float64) (time.Time, bool) {
	if math.IsNaN(value) || math.IsInf(value, 0) || value < -62135596800 || value >= 253402300800 {
		return time.Time{}, false
	}
	whole := math.Floor(value)
	return time.Unix(int64(whole), int64((value-whole)*1e9)), true
}

func runtimePromptStamp(value time.Time, location *time.Location) string {
	local := value.In(location)
	if location.String() == "UTC"+local.Format("-07:00") {
		return fmt.Sprintf("%s（%s）", local.Format("2006年1月2日 15:04:05"), location)
	}
	return fmt.Sprintf("%s（%s，UTC%s）", local.Format("2006年1月2日 15:04:05"), location, local.Format("-07:00"))
}
