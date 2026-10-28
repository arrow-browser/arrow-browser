package share

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/euskadi31/arrow-browser/server/internal/auth"
)

const publicURL = "https://arrow.example"

func fakeAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if id == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithUser(r.Context(), auth.User{ID: id})))
	})
}

func newTestMux(t *testing.T) *http.ServeMux {
	t.Helper()
	names := map[string]string{"alice": "Alice <script>"}
	s, err := NewService(filepath.Join(t.TempDir(), "shares.json"), publicURL, func(id string) string { return names[id] })
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	s.Routes(mux, fakeAuth)
	return mux
}

func do(t *testing.T, mux http.Handler, method, path, user string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	if user != "" {
		req.Header.Set("Authorization", "Bearer "+user)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func create(t *testing.T, mux http.Handler, user string, body any) (id, url string) {
	t.Helper()
	rec := do(t, mux, http.MethodPost, "/v1/shares", user, body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d %s", rec.Code, rec.Body)
	}
	var res struct{ ID, URL, CreatedAt string }
	_ = json.Unmarshal(rec.Body.Bytes(), &res)
	if res.CreatedAt == "" {
		t.Fatal("missing createdAt")
	}
	return res.ID, res.URL
}

var spacePayload = map[string]any{"items": []map[string]string{
	{"title": "Arrow <b>repo</b>", "url": "https://github.com/euskadi31/arrow-browser"},
	{"title": "evil", "url": "javascript:alert(1)"},
	{"title": "", "url": "http://example.com/path?q=1"},
}}

func TestCreateGetListDelete(t *testing.T) {
	mux := newTestMux(t)
	id, url := create(t, mux, "alice", map[string]any{"kind": "space", "title": "Research", "payload": spacePayload})
	if !regexp.MustCompile(`^[0-9A-Za-z]{10}$`).MatchString(id) || url != publicURL+"/s/"+id {
		t.Fatalf("id=%q url=%q", id, url)
	}

	// Public read, no auth.
	rec := do(t, mux, http.MethodGet, "/v1/shares/"+id, "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get = %d", rec.Code)
	}
	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["kind"] != "space" || got["title"] != "Research" || got["owner"].(map[string]any)["displayName"] != "Alice <script>" {
		t.Fatalf("get = %v", got)
	}
	if _, leaked := got["ownerId"]; leaked {
		t.Fatal("ownerId must not be public")
	}
	if items := got["payload"].(map[string]any)["items"].([]any); len(items) != 3 {
		t.Fatalf("payload not returned verbatim: %v", got["payload"])
	}

	create(t, mux, "bob", map[string]any{"kind": "note", "title": "Bob's", "payload": map[string]string{"text": "hi"}})
	rec = do(t, mux, http.MethodGet, "/v1/shares", "alice", nil)
	var list struct{ Shares []summary }
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	if rec.Code != http.StatusOK || len(list.Shares) != 1 || list.Shares[0].ID != id || list.Shares[0].URL != url {
		t.Fatalf("list = %d %+v", rec.Code, list)
	}

	if rec := do(t, mux, http.MethodDelete, "/v1/shares/"+id, "bob", nil); rec.Code != http.StatusForbidden {
		t.Fatalf("delete by non-owner = %d", rec.Code)
	}
	if rec := do(t, mux, http.MethodDelete, "/v1/shares/"+id, "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous delete = %d", rec.Code)
	}
	if rec := do(t, mux, http.MethodDelete, "/v1/shares/"+id, "alice", nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d", rec.Code)
	}
	if rec := do(t, mux, http.MethodGet, "/v1/shares/"+id, "", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("get after delete = %d", rec.Code)
	}
	if rec := do(t, mux, http.MethodDelete, "/v1/shares/"+id, "alice", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("second delete = %d", rec.Code)
	}
}

func TestCreateValidation(t *testing.T) {
	mux := newTestMux(t)
	tests := []struct {
		name string
		body map[string]any
	}{
		{"unknown kind", map[string]any{"kind": "window", "title": "x", "payload": map[string]any{}}},
		{"missing title", map[string]any{"kind": "tab", "title": "  ", "payload": map[string]any{}}},
		{"long title", map[string]any{"kind": "tab", "title": strings.Repeat("x", 201), "payload": map[string]any{}}},
		{"missing payload", map[string]any{"kind": "tab", "title": "x"}},
		{"null payload", map[string]any{"kind": "tab", "title": "x", "payload": nil}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if rec := do(t, mux, http.MethodPost, "/v1/shares", "alice", tt.body); rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d", rec.Code)
			}
		})
	}
	if rec := do(t, mux, http.MethodPost, "/v1/shares", "", map[string]any{"kind": "tab", "title": "x", "payload": 1}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous create = %d", rec.Code)
	}
}

func TestPublicPage(t *testing.T) {
	mux := newTestMux(t)
	id, _ := create(t, mux, "alice", map[string]any{"kind": "space", "title": "<img src=x onerror=alert(1)>", "payload": spacePayload})

	rec := do(t, mux, http.MethodGet, "/s/"+id, "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("page = %d", rec.Code)
	}
	html := rec.Body.String()
	if ct := rec.Header().Get("Content-Type"); ct != "text/html; charset=utf-8" {
		t.Fatalf("Content-Type = %q", ct)
	}
	for _, unwanted := range []string{"<img src=x", "<script>", "<b>repo</b>", "javascript:"} {
		if strings.Contains(html, unwanted) {
			t.Errorf("page contains unescaped %q", unwanted)
		}
	}
	for _, want := range []string{
		`&lt;img src=x onerror=alert(1)&gt;`,
		`Alice &lt;script&gt;`,
		`href="https://github.com/euskadi31/arrow-browser"`,
		`>example.com</a>`,
		`href="arrowBrowser://share/` + id + `"`,
		`Open in Arrow`,
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page missing %q", want)
		}
	}

	// The CSP must allow exactly the inline stylesheet that was rendered.
	csp := rec.Header().Get("Content-Security-Policy")
	m := regexp.MustCompile(`(?s)<style>(.*?)</style>`).FindStringSubmatch(html)
	if m == nil {
		t.Fatal("no <style> element")
	}
	sum := sha256.Sum256([]byte(m[1]))
	if !strings.Contains(csp, "style-src 'sha256-"+base64.StdEncoding.EncodeToString(sum[:])+"'") || !strings.Contains(csp, "default-src 'none'") {
		t.Fatalf("CSP %q does not match rendered style", csp)
	}

	if rec := do(t, mux, http.MethodGet, "/s/doesnotexi", "", nil); rec.Code != http.StatusNotFound {
		t.Fatalf("missing page = %d", rec.Code)
	}
}

func TestNewID(t *testing.T) {
	seen := map[string]bool{}
	for range 1000 {
		id := newID()
		if len(id) != 10 || strings.Trim(id, base62) != "" {
			t.Fatalf("bad id %q", id)
		}
		if seen[id] {
			t.Fatalf("duplicate id %q", id)
		}
		seen[id] = true
	}
}
