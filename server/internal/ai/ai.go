// Package ai replaces the Arc Max backend (ai-service / aiproxy /
// webresultproxy). Each task has a fixed server-side system prompt; the
// Anthropic API key never leaves the server.
package ai

import (
	"context"
	"fmt"
)

// DefaultModel is used when ARROW_AI_MODEL is not set.
const DefaultModel = "claude-opus-5-5"

// Message is one conversation turn.
type Message struct {
	Role    string `json:"role"` // "user" or "assistant"
	Content string `json:"content"`
}

// Request is a provider-neutral completion request.
type Request struct {
	Model     string
	System    string
	Messages  []Message
	MaxTokens int64
	Effort    string // output_config.effort: "low" or "medium"
}

// Usage reports token consumption.
type Usage struct {
	InputTokens  int64 `json:"inputTokens"`
	OutputTokens int64 `json:"outputTokens"`
}

// Result is a finished completion. Text is empty when StopReason is
// "refusal": refused output must never be shown as an answer.
type Result struct {
	Text       string
	StopReason string
	Model      string
	Usage      Usage
}

// Client is the model provider. The Anthropic implementation lives in
// anthropic.go; tests substitute a fake.
type Client interface {
	Complete(ctx context.Context, req Request) (Result, error)
	// Stream calls onText for every text delta, in order.
	Stream(ctx context.Context, req Request, onText func(string) error) (Result, error)
}

// UpstreamError is an error status returned by the model provider.
type UpstreamError struct {
	StatusCode int
	Err        error
}

func (e *UpstreamError) Error() string { return fmt.Sprintf("ai upstream %d: %v", e.StatusCode, e.Err) }
func (e *UpstreamError) Unwrap() error { return e.Err }

// task describes one Arc Max feature.
type task struct {
	system       string
	effort       string
	maxTokens    int64 // upper bound and default for max_tokens
	allowsSystem bool  // whether the client may supply its own system prompt
}

const (
	tidyMaxTokens    = 1024
	defaultMaxTokens = 16000
)

var tasks = map[string]task{
	"tidy-tab-title": {
		effort:    "low",
		maxTokens: tidyMaxTokens,
		system: "You rename browser tabs. The user message contains a page title and its URL. " +
			"Reply with only a concise title of 1 to 5 words that tells the user what the page is, " +
			"in the language of the original title. No quotes, no trailing punctuation, no explanation.",
	},
	"tidy-download-name": {
		effort:    "low",
		maxTokens: tidyMaxTokens,
		system: "You rename downloaded files. The user message contains the original file name and, " +
			"when available, the source URL and page title. Reply with only a short, human-readable file name " +
			"of at most 8 words that keeps the original extension. No quotes, no directory, no explanation.",
	},
	"preview-summary": {
		effort:    "medium",
		maxTokens: defaultMaxTokens,
		system: "You write link previews for a web browser. The user message contains the title, URL and text of a web page. " +
			"Summarize what the page offers in at most 5 short bullet points, in the language of the page, " +
			"using only information found in the page. Reply with the bullet points only.",
	},
	"ask-page": {
		effort:    "medium",
		maxTokens: defaultMaxTokens,
		system: "You answer questions about the web page the user is viewing. The conversation contains the page's " +
			"title, URL and text, followed by the user's questions. Answer from the page content, concisely; " +
			"if the page does not contain the answer, say so briefly.",
	},
	"tidy-tabs": {
		effort:    "low",
		maxTokens: 4096,
		system: "You organize browser tabs. The user message lists tabs, one per line, as `<number>. <title> — <site>`. " +
			"Group them by topic or task, with as few groups as is useful. Reply with JSON only, no code fence: " +
			"{\"groups\":[{\"name\":\"<2 to 4 words>\",\"tabs\":[<numbers>]}]}. Every number appears exactly once.",
	},
	"chat": {
		effort:       "medium",
		maxTokens:    defaultMaxTokens,
		allowsSystem: true,
		system:       "You are the assistant built into the Arrow web browser. Be helpful, accurate and concise.",
	},
}
