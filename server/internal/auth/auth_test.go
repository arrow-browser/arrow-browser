package auth

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testIterations = 1000 // keeps tests fast; production uses DefaultIterations

func newTestService(t *testing.T) (*Service, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "auth.json")
	s, err := NewService(path)
	if err != nil {
		t.Fatal(err)
	}
	s.iterations = testIterations
	return s, path
}

func newTestMux(s *Service) *http.ServeMux {
	mux := http.NewServeMux()
	s.Routes(mux)
	return mux
}

func do(t *testing.T, h http.Handler, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var env struct {
		Error struct{ Code string } `json:"error"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &env)
	return env.Error.Code
}

func TestPasswordHashing(t *testing.T) {
	hash, err := hashPassword("correct horse", testIterations)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(hash, "pbkdf2_sha256$1000$") {
		t.Fatalf("unexpected hash format %q", hash)
	}
	other, _ := hashPassword("correct horse", testIterations)
	if hash == other {
		t.Fatal("salts must differ between hashes")
	}
	if ok, err := verifyPassword("correct horse", hash); err != nil || !ok {
		t.Fatalf("verify correct password = %v, %v", ok, err)
	}
	if ok, _ := verifyPassword("wrong horse", hash); ok {
		t.Fatal("wrong password accepted")
	}
	if _, err := verifyPassword("x", "md5$abc"); err == nil {
		t.Fatal("unknown scheme accepted")
	}
}

func TestDefaultIterationsMeetPolicy(t *testing.T) {
	s, err := NewService(filepath.Join(t.TempDir(), "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	if s.iterations < 600_000 {
		t.Fatalf("default iterations = %d, want >= 600000", s.iterations)
	}
}

func TestRegisterLoginMeLogout(t *testing.T) {
	s, path := newTestService(t)
	mux := newTestMux(s)

	rec := do(t, mux, http.MethodPost, "/v1/auth/register", "", map[string]string{
		"email": " Alice@Example.com ", "password": "s3cret-pass", "displayName": "Alice",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("register status = %d body=%s", rec.Code, rec.Body)
	}
	var reg sessionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &reg); err != nil {
		t.Fatal(err)
	}
	if reg.Token == "" || reg.User.ID == "" || reg.User.Email != "alice@example.com" || reg.User.DisplayName != "Alice" || reg.User.CreatedAt.IsZero() {
		t.Fatalf("register response = %+v", reg)
	}

	// The database must hold neither the raw token nor the password.
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(reg.Token)) || bytes.Contains(raw, []byte("s3cret-pass")) {
		t.Fatal("secret stored in plaintext")
	}

	rec = do(t, mux, http.MethodGet, "/v1/me", reg.Token, nil)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"alice@example.com"`) {
		t.Fatalf("me = %d %s", rec.Code, rec.Body)
	}

	rec = do(t, mux, http.MethodPost, "/v1/auth/login", "", map[string]string{"email": "ALICE@example.com", "password": "s3cret-pass"})
	if rec.Code != http.StatusOK {
		t.Fatalf("login status = %d body=%s", rec.Code, rec.Body)
	}
	var login sessionResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &login)
	if login.Token == "" || login.Token == reg.Token || login.User.ID != reg.User.ID {
		t.Fatalf("login response = %+v", login)
	}

	rec = do(t, mux, http.MethodPost, "/v1/auth/logout", reg.Token, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("logout status = %d", rec.Code)
	}
	if rec = do(t, mux, http.MethodGet, "/v1/me", reg.Token, nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("revoked token still works: %d", rec.Code)
	}
	if rec = do(t, mux, http.MethodGet, "/v1/me", login.Token, nil); rec.Code != http.StatusOK {
		t.Fatalf("other session was revoked too: %d", rec.Code)
	}

	// Sessions survive a restart.
	s2, err := NewService(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s2.Authenticate(login.Token); err != nil {
		t.Fatalf("token lost after reopen: %v", err)
	}
}

func TestRegisterValidation(t *testing.T) {
	s, _ := newTestService(t)
	mux := newTestMux(s)
	ok := map[string]string{"email": "bob@example.com", "password": "password1", "displayName": "Bob"}
	if rec := do(t, mux, http.MethodPost, "/v1/auth/register", "", ok); rec.Code != http.StatusCreated {
		t.Fatalf("register = %d", rec.Code)
	}

	tests := []struct {
		name     string
		body     map[string]string
		status   int
		wantCode string
	}{
		{"duplicate email", map[string]string{"email": "BOB@example.com", "password": "password1"}, http.StatusConflict, "email_taken"},
		{"invalid email", map[string]string{"email": "not-an-email", "password": "password1"}, http.StatusBadRequest, "invalid_request"},
		{"email with display name", map[string]string{"email": "Bob <b@example.com>", "password": "password1"}, http.StatusBadRequest, "invalid_request"},
		{"short password", map[string]string{"email": "c@example.com", "password": "short"}, http.StatusBadRequest, "invalid_request"},
		{"long display name", map[string]string{"email": "d@example.com", "password": "password1", "displayName": strings.Repeat("x", 101)}, http.StatusBadRequest, "invalid_request"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := do(t, mux, http.MethodPost, "/v1/auth/register", "", tt.body)
			if rec.Code != tt.status || errorCode(t, rec) != tt.wantCode {
				t.Fatalf("got %d %s", rec.Code, rec.Body)
			}
		})
	}

	_, user, err := s.Register("eve@example.com", "password1", "")
	if err != nil || user.DisplayName != "eve" {
		t.Fatalf("default display name = %q, %v", user.DisplayName, err)
	}
}

func TestLoginDoesNotEnumerateUsers(t *testing.T) {
	s, _ := newTestService(t)
	mux := newTestMux(s)
	if _, _, err := s.Register("carol@example.com", "password1", "Carol"); err != nil {
		t.Fatal(err)
	}
	wrongPassword := do(t, mux, http.MethodPost, "/v1/auth/login", "", map[string]string{"email": "carol@example.com", "password": "nope-nope"})
	unknownUser := do(t, mux, http.MethodPost, "/v1/auth/login", "", map[string]string{"email": "nobody@example.com", "password": "password1"})
	if wrongPassword.Code != http.StatusUnauthorized || unknownUser.Code != http.StatusUnauthorized {
		t.Fatalf("statuses = %d, %d", wrongPassword.Code, unknownUser.Code)
	}
	if wrongPassword.Body.String() != unknownUser.Body.String() {
		t.Fatalf("responses differ:\n%s\n%s", wrongPassword.Body, unknownUser.Body)
	}
}

func TestTokenExpiry(t *testing.T) {
	s, _ := newTestService(t)
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	token, _, err := s.Register("dan@example.com", "password1", "Dan")
	if err != nil {
		t.Fatal(err)
	}
	now = now.Add(TokenTTL - time.Second)
	if _, err := s.Authenticate(token); err != nil {
		t.Fatalf("token expired early: %v", err)
	}
	now = now.Add(time.Second)
	if _, err := s.Authenticate(token); err == nil {
		t.Fatal("token valid after TTL")
	}

	// Expired sessions are pruned on the next write.
	if _, _, err := s.Login("dan@example.com", "password1"); err != nil {
		t.Fatal(err)
	}
	s.db.View(func(st *state) {
		if len(st.Tokens) != 1 {
			t.Fatalf("tokens = %d, want 1 after prune", len(st.Tokens))
		}
	})
}

func TestMiddleware(t *testing.T) {
	s, _ := newTestService(t)
	token, user, err := s.Register("erin@example.com", "password1", "Erin")
	if err != nil {
		t.Fatal(err)
	}
	echo := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, ok := FromContext(r.Context())
		if !ok {
			w.Write([]byte("anonymous"))
			return
		}
		w.Write([]byte(u.ID))
	})

	tests := []struct {
		name       string
		handler    http.Handler
		header     string
		wantStatus int
		wantBody   string
	}{
		{"require ok", s.Require(echo), "Bearer " + token, 200, user.ID},
		{"require lowercase scheme", s.Require(echo), "bearer " + token, 200, user.ID},
		{"require missing", s.Require(echo), "", 401, ""},
		{"require bad token", s.Require(echo), "Bearer nope", 401, ""},
		{"require basic auth", s.Require(echo), "Basic abc", 401, ""},
		{"optional ok", s.Optional(echo), "Bearer " + token, 200, user.ID},
		{"optional bad token", s.Optional(echo), "Bearer nope", 200, "anonymous"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/", nil)
			if tt.header != "" {
				req.Header.Set("Authorization", tt.header)
			}
			rec := httptest.NewRecorder()
			tt.handler.ServeHTTP(rec, req)
			if rec.Code != tt.wantStatus {
				t.Fatalf("status = %d", rec.Code)
			}
			if tt.wantStatus == 200 && rec.Body.String() != tt.wantBody {
				t.Fatalf("body = %q", rec.Body)
			}
			if tt.wantStatus == 401 && rec.Header().Get("WWW-Authenticate") == "" {
				t.Fatal("missing WWW-Authenticate")
			}
		})
	}
}

func TestCredentialEndpointsAreRateLimited(t *testing.T) {
	s, _ := newTestService(t)
	mux := newTestMux(s)
	var last *httptest.ResponseRecorder
	for range 21 {
		last = do(t, mux, http.MethodPost, "/v1/auth/login", "", map[string]string{"email": "x@example.com", "password": "password1"})
	}
	if last.Code != http.StatusTooManyRequests || last.Header().Get("Retry-After") == "" {
		t.Fatalf("21st attempt = %d", last.Code)
	}
}
