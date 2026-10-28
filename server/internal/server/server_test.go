package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/euskadi31/arrow-browser/server/internal/ai"
	"github.com/euskadi31/arrow-browser/server/internal/config"
)

type echoAI struct{}

func (echoAI) Complete(_ context.Context, req ai.Request) (ai.Result, error) {
	return ai.Result{Text: "echo: " + req.Messages[0].Content, StopReason: "end_turn", Model: req.Model}, nil
}

func (echoAI) Stream(ctx context.Context, req ai.Request, onText func(string) error) (ai.Result, error) {
	res, _ := echoAI{}.Complete(ctx, req)
	return res, onText(res.Text)
}

type client struct {
	t     *testing.T
	base  string
	token string
}

func (c *client) do(method, path string, body any, out any) *http.Response {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, c.base+path, &buf)
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			c.t.Fatalf("%s %s: decode %q: %v", method, path, data, err)
		}
	}
	resp.Body = io.NopCloser(bytes.NewReader(data))
	return resp
}

func newTestServer(t *testing.T, aiClient ai.Client) *client {
	t.Helper()
	cfg := config.Config{DataDir: t.TempDir(), PublicURL: "https://arrow.example", AIModel: "claude-opus-5-5"}
	srv, err := New(cfg, "test", aiClient, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler)
	t.Cleanup(func() {
		srv.Close()
		ts.Close()
	})
	return &client{t: t, base: ts.URL}
}

func TestHealthAndFallbacks(t *testing.T) {
	c := newTestServer(t, nil)

	var health map[string]string
	resp := c.do(http.MethodGet, "/healthz", nil, &health)
	if resp.StatusCode != 200 || health["status"] != "ok" || health["version"] != "test" {
		t.Fatalf("healthz = %d %v", resp.StatusCode, health)
	}
	if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("security headers missing")
	}

	var env struct{ Error struct{ Code string } }
	if resp := c.do(http.MethodGet, "/v1/nope", nil, &env); resp.StatusCode != 404 || env.Error.Code != "not_found" {
		t.Fatalf("unknown route = %d %+v", resp.StatusCode, env)
	}
	if resp := c.do(http.MethodDelete, "/v1/config", nil, &env); resp.StatusCode != 404 || env.Error.Code != "not_found" {
		t.Fatalf("wrong method = %d %+v", resp.StatusCode, env)
	}
	for _, path := range []string{"/v1/me", "/v1/sync/changes", "/v1/shares"} {
		if resp := c.do(http.MethodGet, path, nil, nil); resp.StatusCode != 401 {
			t.Errorf("%s without token = %d", path, resp.StatusCode)
		}
	}

	// Public endpoints work out of the box with an empty data dir.
	var cfg map[string]map[string]any
	c.do(http.MethodGet, "/v1/config", nil, &cfg)
	if cfg["flags"]["aiFeatures"] != false {
		t.Fatalf("aiFeatures should be false without an AI client: %v", cfg["flags"])
	}
	if resp := c.do(http.MethodGet, "/v1/blocklists/manifest.json", nil, nil); resp.StatusCode != 200 {
		t.Fatalf("manifest = %d", resp.StatusCode)
	}
	if resp := c.do(http.MethodGet, "/v1/updates/appcast.xml", nil, nil); resp.StatusCode != 200 {
		t.Fatalf("appcast = %d", resp.StatusCode)
	}
	if resp := c.do(http.MethodPost, "/v1/feedback", map[string]string{"message": "hi"}, nil); resp.StatusCode != 202 {
		t.Fatalf("feedback = %d", resp.StatusCode)
	}
}

func TestEndToEnd(t *testing.T) {
	c := newTestServer(t, echoAI{})

	var session struct {
		Token string
		User  struct{ ID, DisplayName string }
	}
	resp := c.do(http.MethodPost, "/v1/auth/register", map[string]string{
		"email": "ada@example.com", "password": "correct horse battery", "displayName": "Ada",
	}, &session)
	if resp.StatusCode != 201 {
		t.Fatalf("register = %d", resp.StatusCode)
	}
	c.token = session.Token

	var push struct {
		Revision int64
		Accepted []string
	}
	c.do(http.MethodPost, "/v1/sync/push", map[string]any{
		"deviceId": "mac",
		"changes":  []map[string]any{{"id": "s1", "kind": "space", "payload": "Y2lwaGVy", "baseRevision": 0}},
	}, &push)
	if push.Revision != 1 || len(push.Accepted) != 1 {
		t.Fatalf("push = %+v", push)
	}

	var created struct{ ID, URL string }
	c.do(http.MethodPost, "/v1/shares", map[string]any{
		"kind": "folder", "title": "Reading", "payload": map[string]any{"items": []map[string]string{{"title": "Go", "url": "https://go.dev"}}},
	}, &created)
	if !strings.HasPrefix(created.URL, "https://arrow.example/s/") {
		t.Fatalf("share = %+v", created)
	}
	var shared struct{ Owner struct{ DisplayName string } }
	anon := &client{t: t, base: c.base}
	anon.do(http.MethodGet, "/v1/shares/"+created.ID, nil, &shared)
	if shared.Owner.DisplayName != "Ada" {
		t.Fatalf("owner = %+v", shared)
	}
	page := anon.do(http.MethodGet, "/s/"+created.ID, nil, nil)
	if csp := page.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "style-src 'sha256-") {
		t.Fatalf("share page CSP not overridden: %q", csp)
	}

	var answer struct{ Text, Model string }
	c.do(http.MethodPost, "/v1/ai/messages", map[string]any{
		"task": "chat", "messages": []map[string]string{{"role": "user", "content": "ping"}},
	}, &answer)
	if answer.Text != "echo: ping" || answer.Model != "claude-opus-5-5" {
		t.Fatalf("ai = %+v", answer)
	}

	if resp := c.do(http.MethodPost, "/v1/auth/logout", nil, nil); resp.StatusCode != 204 {
		t.Fatalf("logout = %d", resp.StatusCode)
	}
	if resp := c.do(http.MethodGet, "/v1/me", nil, nil); resp.StatusCode != 401 {
		t.Fatalf("me after logout = %d", resp.StatusCode)
	}
}
