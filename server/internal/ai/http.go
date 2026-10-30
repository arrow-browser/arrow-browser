package ai

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/arrow-browser/arrow-browser/server/internal/auth"
	"github.com/arrow-browser/arrow-browser/server/internal/httpx"
	"github.com/arrow-browser/arrow-browser/server/internal/ratelimit"
)

const (
	maxBody     = 2 << 20
	maxMessages = 100
	// requestsPerMinute is the per-user budget for AI calls.
	requestsPerMinute = 30
	// completionDeadline extends the server write timeout while the model thinks.
	completionDeadline = 10 * time.Minute
)

// Handler serves POST /v1/ai/messages.
type Handler struct {
	client  Client // nil when no API key is configured
	model   string
	limiter *ratelimit.Limiter
	logger  *slog.Logger
}

// NewHandler proxies AI requests to client using model. A nil client
// disables the endpoint (503).
func NewHandler(client Client, model string, logger *slog.Logger) *Handler {
	if model == "" {
		model = DefaultModel
	}
	return &Handler{client: client, model: model, limiter: ratelimit.New(requestsPerMinute, time.Minute), logger: logger}
}

// Routes registers the AI endpoint behind requireAuth.
func (h *Handler) Routes(mux *http.ServeMux, requireAuth func(http.Handler) http.Handler) {
	mux.Handle("POST /v1/ai/messages", requireAuth(httpx.HandlerFunc(h.handleMessages)))
}

type messagesRequest struct {
	Task      string    `json:"task"`
	System    string    `json:"system"`
	Messages  []Message `json:"messages"`
	Stream    bool      `json:"stream"`
	MaxTokens int64     `json:"maxTokens"`
}

// build validates the client request and turns it into a model request.
func (h *Handler) build(in messagesRequest) (Request, error) {
	t, ok := tasks[in.Task]
	if !ok {
		return Request{}, httpx.BadRequest("task must be one of tidy-tab-title, tidy-download-name, tidy-tabs, preview-summary, ask-page, chat")
	}
	if in.System != "" && !t.allowsSystem {
		return Request{}, httpx.BadRequest("system is only allowed for the chat task")
	}
	if len(in.Messages) == 0 || len(in.Messages) > maxMessages {
		return Request{}, httpx.BadRequest(fmt.Sprintf("messages must contain between 1 and %d entries", maxMessages))
	}
	for i, m := range in.Messages {
		if m.Role != "user" && m.Role != "assistant" {
			return Request{}, httpx.BadRequest(fmt.Sprintf("messages[%d].role must be user or assistant", i))
		}
		if m.Content == "" {
			return Request{}, httpx.BadRequest(fmt.Sprintf("messages[%d].content is empty", i))
		}
	}
	if in.Messages[len(in.Messages)-1].Role != "user" {
		return Request{}, httpx.BadRequest("the last message must have role user")
	}
	system := t.system
	if in.System != "" {
		system = in.System
	}
	maxTokens := t.maxTokens
	if in.MaxTokens > 0 && in.MaxTokens < maxTokens {
		maxTokens = in.MaxTokens
	}
	return Request{Model: h.model, System: system, Messages: in.Messages, MaxTokens: maxTokens, Effort: t.effort}, nil
}

func (h *Handler) handleMessages(w http.ResponseWriter, r *http.Request) error {
	if h.client == nil {
		return httpx.NewError(http.StatusServiceUnavailable, "ai_disabled", "AI features are not configured on this server")
	}
	user, _ := auth.FromContext(r.Context())
	if ok, wait := h.limiter.Allow(user.ID); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		return httpx.NewError(http.StatusTooManyRequests, "rate_limited", "too many AI requests, retry later")
	}
	var in messagesRequest
	if err := httpx.DecodeJSON(w, r, &in, maxBody); err != nil {
		return err
	}
	req, err := h.build(in)
	if err != nil {
		return err
	}
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(completionDeadline))
	if in.Stream {
		return h.stream(w, r, in.Task, req)
	}
	res, err := h.client.Complete(r.Context(), req)
	if err != nil {
		return h.upstreamFailure(r, in.Task, err)
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Text       string `json:"text"`
		StopReason string `json:"stopReason"`
		Model      string `json:"model"`
		Usage      Usage  `json:"usage"`
	}{res.Text, res.StopReason, res.Model, res.Usage})
	return nil
}

// stream relays text deltas as SSE. Headers are only sent with the first
// event, so a request that fails up front still gets a JSON error status.
func (h *Handler) stream(w http.ResponseWriter, r *http.Request, task string, req Request) error {
	sse := httpx.NewSSE(w)
	res, err := h.client.Stream(r.Context(), req, func(text string) error {
		return sse.Event("delta", map[string]string{"text": text})
	})
	if err != nil {
		apiErr := h.upstreamFailure(r, task, err)
		if !sse.Started() {
			return apiErr
		}
		var e *httpx.Error
		if errors.As(apiErr, &e) {
			_ = sse.Event("error", map[string]map[string]string{"error": {"code": e.Code, "message": e.Message}})
		}
		return nil
	}
	_ = sse.Event("done", struct {
		StopReason string `json:"stopReason"`
		Usage      Usage  `json:"usage"`
	}{res.StopReason, res.Usage})
	return nil
}

// upstreamFailure logs a provider error and maps it to a client-facing one
// without leaking provider details.
func (h *Handler) upstreamFailure(r *http.Request, task string, err error) error {
	if r.Context().Err() != nil {
		return httpx.NewError(499, "client_closed", "request cancelled")
	}
	h.logger.WarnContext(r.Context(), "ai upstream error", "task", task, "err", err)
	var up *UpstreamError
	if errors.As(err, &up) && (up.StatusCode == http.StatusTooManyRequests || up.StatusCode == 529 || up.StatusCode == http.StatusServiceUnavailable) {
		return httpx.NewError(http.StatusServiceUnavailable, "ai_unavailable", "the AI service is busy, retry later")
	}
	return httpx.NewError(http.StatusBadGateway, "ai_upstream_error", "the AI service returned an error")
}
