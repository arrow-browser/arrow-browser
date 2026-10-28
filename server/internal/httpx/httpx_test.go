package httpx

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func decodeError(t *testing.T, body io.Reader) (code, message string) {
	t.Helper()
	var env struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(body).Decode(&env); err != nil {
		t.Fatalf("decode error envelope: %v", err)
	}
	return env.Error.Code, env.Error.Message
}

func TestHandlerFuncRendersErrors(t *testing.T) {
	tests := []struct {
		name       string
		err        error
		wantStatus int
		wantCode   string
	}{
		{"api error", NotFound("nope"), http.StatusNotFound, "not_found"},
		{"wrapped api error", errors.Join(errors.New("ctx"), BadRequest("bad")), http.StatusBadRequest, "invalid_request"},
		{"internal error is hidden", errors.New("disk on fire"), http.StatusInternalServerError, "internal"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := HandlerFunc(func(http.ResponseWriter, *http.Request) error { return tt.err })
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			code, msg := decodeError(t, rec.Body)
			if code != tt.wantCode {
				t.Fatalf("code = %q, want %q", code, tt.wantCode)
			}
			if strings.Contains(msg, "disk") {
				t.Fatalf("internal error message leaked: %q", msg)
			}
		})
	}
}

func TestDecodeJSON(t *testing.T) {
	type payload struct {
		Name string `json:"name"`
	}
	tests := []struct {
		name       string
		body       string
		limit      int64
		wantStatus int // 0 = success
	}{
		{"ok", `{"name":"arrow"}`, 1024, 0},
		{"empty", ``, 1024, http.StatusBadRequest},
		{"malformed", `{"name":`, 1024, http.StatusBadRequest},
		{"trailing data", `{"name":"a"} {"name":"b"}`, 1024, http.StatusBadRequest},
		{"too large", `{"name":"` + strings.Repeat("x", 100) + `"}`, 16, http.StatusRequestEntityTooLarge},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(tt.body))
			var p payload
			err := DecodeJSON(httptest.NewRecorder(), r, &p, tt.limit)
			if tt.wantStatus == 0 {
				if err != nil || p.Name != "arrow" {
					t.Fatalf("DecodeJSON = %v, %+v", err, p)
				}
				return
			}
			var apiErr *Error
			if !errors.As(err, &apiErr) || apiErr.Status != tt.wantStatus {
				t.Fatalf("DecodeJSON error = %v, want status %d", err, tt.wantStatus)
			}
		})
	}
}

func TestSecurityHeadersAndRecover(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	h := Chain(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom") }),
		Recover(logger), Log(logger), SecurityHeaders)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d", rec.Code)
	}
	for _, name := range []string{"X-Content-Type-Options", "X-Frame-Options", "Content-Security-Policy", "Referrer-Policy"} {
		if rec.Header().Get(name) == "" {
			t.Errorf("missing header %s", name)
		}
	}
}

func TestNotModified(t *testing.T) {
	etag := StrongETag([]byte("hello"))
	tests := []struct {
		header string
		want   bool
	}{
		{"", false},
		{etag, true},
		{"W/" + etag, true},
		{`"other", ` + etag, true},
		{"*", true},
		{`"other"`, false},
	}
	for _, tt := range tests {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if tt.header != "" {
			r.Header.Set("If-None-Match", tt.header)
		}
		if got := NotModified(r, etag); got != tt.want {
			t.Errorf("NotModified(%q) = %v, want %v", tt.header, got, tt.want)
		}
	}
}

func TestSSEThroughLogMiddleware(t *testing.T) {
	h := Log(slog.New(slog.DiscardHandler))(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sse := NewSSE(w)
		if sse.Started() {
			t.Error("started before first event")
		}
		if err := sse.Event("revision", map[string]int{"revision": 3}); err != nil {
			t.Errorf("Event: %v", err)
		}
		if err := sse.Comment("keep-alive"); err != nil {
			t.Errorf("Comment: %v", err)
		}
	}))
	srv := httptest.NewServer(h)
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("Content-Type = %q", ct)
	}
	var lines []string
	sc := bufio.NewScanner(resp.Body)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	got := strings.Join(lines, "\n")
	want := "event: revision\ndata: {\"revision\":3}\n\n: keep-alive\n"
	if got != want {
		t.Fatalf("stream = %q, want %q", got, want)
	}
}
