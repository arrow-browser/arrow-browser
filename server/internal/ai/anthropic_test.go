package ai

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go/v2/option"
)

// fakeAPI stands in for api.anthropic.com so the real SDK code path runs
// without network access or an API key.
type fakeAPI struct {
	t        *testing.T
	body     map[string]any
	header   http.Header
	status   int
	response string
	stream   string
}

func (f *fakeAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/messages" {
		f.t.Errorf("unexpected path %s", r.URL.Path)
	}
	raw, _ := io.ReadAll(r.Body)
	f.body = map[string]any{}
	if err := json.Unmarshal(raw, &f.body); err != nil {
		f.t.Errorf("request body is not JSON: %v", err)
	}
	f.header = r.Header.Clone()
	if f.status != 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(f.status)
		io.WriteString(w, `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`)
		return
	}
	if f.stream != "" {
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, f.stream)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	io.WriteString(w, f.response)
}

func newFakeAPI(t *testing.T) (*fakeAPI, *Anthropic) {
	t.Helper()
	api := &fakeAPI{t: t}
	srv := httptest.NewServer(api)
	t.Cleanup(srv.Close)
	return api, NewAnthropic("test-key", option.WithBaseURL(srv.URL), option.WithMaxRetries(0))
}

var testRequest = Request{
	Model:     "claude-opus-5-5",
	System:    "fixed system prompt",
	Messages:  []Message{{Role: "user", Content: "first"}, {Role: "assistant", Content: "reply"}, {Role: "user", Content: "second"}},
	MaxTokens: 1024,
	Effort:    "low",
}

func TestAnthropicRequestShape(t *testing.T) {
	api, client := newFakeAPI(t)
	api.response = `{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5",
		"content":[{"type":"text","text":"Arrow "},{"type":"text","text":"Repo"}],
		"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":21,"output_tokens":4}}`

	res, err := client.Complete(context.Background(), testRequest)
	if err != nil {
		t.Fatal(err)
	}
	if res.Text != "Arrow Repo" || res.StopReason != "end_turn" || res.Model != "claude-opus-5-5" || res.Usage != (Usage{21, 4}) {
		t.Fatalf("result = %+v", res)
	}

	if api.header.Get("Authorization") != "Bearer test-key" && api.header.Get("X-Api-Key") != "test-key" {
		t.Errorf("API key not sent: %v", api.header)
	}
	if beta := api.header.Get("Anthropic-Beta"); !strings.Contains(beta, "server-side-fallback-2026-07-01") {
		t.Errorf("anthropic-beta = %q, want server-side-fallback-2026-07-01", beta)
	}
	b := api.body
	if b["model"] != "claude-opus-5-5" || b["max_tokens"] != float64(1024) || b["fallbacks"] != "default" {
		t.Errorf("body = %v", b)
	}
	if oc, _ := b["output_config"].(map[string]any); oc["effort"] != "low" {
		t.Errorf("output_config = %v", b["output_config"])
	}
	for _, forbidden := range []string{"temperature", "top_p", "top_k", "thinking", "stream"} {
		if _, ok := b[forbidden]; ok {
			t.Errorf("request must not set %q", forbidden)
		}
	}
	system, _ := b["system"].([]any)
	if len(system) != 1 || system[0].(map[string]any)["text"] != "fixed system prompt" {
		t.Errorf("system = %v", b["system"])
	}
	msgs, _ := b["messages"].([]any)
	if len(msgs) != 3 {
		t.Fatalf("messages = %v", b["messages"])
	}
	for i, wantRole := range []string{"user", "assistant", "user"} {
		if role := msgs[i].(map[string]any)["role"]; role != wantRole {
			t.Errorf("messages[%d].role = %v, want %s", i, role, wantRole)
		}
	}
}

func TestAnthropicRefusalDiscardsContent(t *testing.T) {
	api, client := newFakeAPI(t)
	api.response = `{"id":"msg_2","type":"message","role":"assistant","model":"claude-opus-5-5",
		"content":[{"type":"text","text":"partial answer that must not be shown"}],
		"stop_reason":"refusal","stop_sequence":null,
		"stop_details":{"type":"refusal","category":"cyber","explanation":null},
		"usage":{"input_tokens":30,"output_tokens":7}}`
	res, err := client.Complete(context.Background(), testRequest)
	if err != nil {
		t.Fatal(err)
	}
	if res.StopReason != "refusal" || res.Text != "" {
		t.Fatalf("refusal result = %+v", res)
	}
}

func TestAnthropicUpstreamError(t *testing.T) {
	api, client := newFakeAPI(t)
	api.status = 529
	_, err := client.Complete(context.Background(), testRequest)
	var up *UpstreamError
	if !errors.As(err, &up) || up.StatusCode != 529 {
		t.Fatalf("err = %v", err)
	}
}

const streamFixture = `event: message_start
data: {"type":"message_start","message":{"id":"msg_3","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hidden"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}

event: message_stop
data: {"type":"message_stop"}

`

func TestAnthropicStream(t *testing.T) {
	api, client := newFakeAPI(t)
	api.stream = streamFixture
	var deltas []string
	res, err := client.Stream(context.Background(), testRequest, func(text string) error {
		deltas = append(deltas, text)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(deltas, "|") != "Hello| world" {
		t.Fatalf("deltas = %q (thinking must not be forwarded)", deltas)
	}
	if res.StopReason != "end_turn" || res.Usage != (Usage{12, 9}) {
		t.Fatalf("result = %+v", res)
	}
	if api.body["stream"] != true || api.body["fallbacks"] != "default" {
		t.Fatalf("stream body = %v", api.body)
	}
}
