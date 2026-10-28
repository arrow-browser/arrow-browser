package ai

import (
	"context"
	"errors"
	"strings"

	"github.com/anthropics/anthropic-sdk-go/v2"
	"github.com/anthropics/anthropic-sdk-go/v2/option"
	"github.com/anthropics/anthropic-sdk-go/v2/shared/constant"
)

// Anthropic implements Client with the official Anthropic Go SDK.
type Anthropic struct {
	client anthropic.Client
}

// NewAnthropic returns a client authenticated with apiKey. Extra options
// (e.g. option.WithBaseURL in tests) are applied after the key.
func NewAnthropic(apiKey string, opts ...option.RequestOption) *Anthropic {
	opts = append([]option.RequestOption{option.WithAPIKey(apiKey)}, opts...)
	return &Anthropic{client: anthropic.NewClient(opts...)}
}

// params builds the Messages request. Sampling parameters and thinking
// settings are deliberately left unset: the default model rejects
// temperature/top_p/top_k and disabled/budgeted thinking, and effort is the
// supported control. Server-side refusal fallback is opted into by default so
// a policy decline is retried on Anthropic's recommended fallback model.
func params(req Request) anthropic.BetaMessageNewParams {
	msgs := make([]anthropic.BetaMessageParam, 0, len(req.Messages))
	for _, m := range req.Messages {
		block := anthropic.NewBetaTextBlock(m.Content)
		if m.Role == "assistant" {
			msgs = append(msgs, anthropic.BetaMessageParam{OfAssistant: &anthropic.BetaAssistantMessageParam{
				Content: []anthropic.BetaContentBlockParamUnion{block},
			}})
			continue
		}
		msgs = append(msgs, anthropic.NewBetaUserMessage(block))
	}
	p := anthropic.BetaMessageNewParams{
		Model:        req.Model,
		MaxTokens:    req.MaxTokens,
		Messages:     msgs,
		OutputConfig: anthropic.BetaOutputConfigParam{Effort: anthropic.BetaOutputConfigEffort(req.Effort)},
		Fallbacks:    anthropic.BetaFallbacksParamUnion{OfDefault: constant.ValueOf[constant.Default]()},
		Betas:        []anthropic.AnthropicBeta{anthropic.AnthropicBetaServerSideFallback2026_07_01},
	}
	if req.System != "" {
		p.System = []anthropic.BetaTextBlockParam{{Text: req.System}}
	}
	return p
}

// Complete sends a non-streaming request.
func (a *Anthropic) Complete(ctx context.Context, req Request) (Result, error) {
	msg, err := a.client.Beta.Messages.New(ctx, params(req))
	if err != nil {
		return Result{}, upstreamError(err)
	}
	return result(msg), nil
}

// Stream sends a streaming request, forwarding text deltas as they arrive.
func (a *Anthropic) Stream(ctx context.Context, req Request, onText func(string) error) (Result, error) {
	stream := a.client.Beta.Messages.NewStreaming(ctx, params(req))
	defer stream.Close()
	var msg anthropic.BetaMessage
	for stream.Next() {
		event := stream.Current()
		if err := msg.Accumulate(event); err != nil {
			return Result{}, err
		}
		delta, ok := event.AsAny().(anthropic.BetaRawContentBlockDeltaEvent)
		if !ok {
			continue
		}
		if text, ok := delta.Delta.AsAny().(anthropic.BetaTextDelta); ok && text.Text != "" {
			if err := onText(text.Text); err != nil {
				return Result{}, err
			}
		}
	}
	if err := stream.Err(); err != nil {
		return Result{}, upstreamError(err)
	}
	return result(&msg), nil
}

// result checks stop_reason before reading content: on a refusal the
// content is empty or a partial answer that must be discarded.
func result(msg *anthropic.BetaMessage) Result {
	res := Result{
		StopReason: string(msg.StopReason),
		Model:      msg.Model,
		Usage:      Usage{InputTokens: msg.Usage.InputTokens, OutputTokens: msg.Usage.OutputTokens},
	}
	if msg.StopReason == anthropic.BetaStopReasonRefusal {
		return res
	}
	var text strings.Builder
	for _, block := range msg.Content {
		if b, ok := block.AsAny().(anthropic.BetaTextBlock); ok {
			text.WriteString(b.Text)
		}
	}
	res.Text = text.String()
	return res
}

func upstreamError(err error) error {
	var apiErr *anthropic.Error
	if errors.As(err, &apiErr) {
		return &UpstreamError{StatusCode: apiErr.StatusCode, Err: err}
	}
	return err
}
