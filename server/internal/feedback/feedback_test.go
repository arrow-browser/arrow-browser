package feedback

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/arrow-browser/arrow-browser/server/internal/auth"
)

// fakeOptionalAuth authenticates "Bearer <id>" and lets anything else through.
func fakeOptionalAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if id, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
			r = r.WithContext(auth.WithUser(r.Context(), auth.User{ID: id}))
		}
		next.ServeHTTP(w, r)
	})
}

func setup(t *testing.T) (string, *http.ServeMux) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "feedback")
	mux := http.NewServeMux()
	New(dir).Routes(mux, fakeOptionalAuth)
	return dir, mux
}

func post(mux http.Handler, user string, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/feedback", strings.NewReader(body))
	if user != "" {
		req.Header.Set("Authorization", "Bearer "+user)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestSubmitStoresReport(t *testing.T) {
	dir, mux := setup(t)
	rec := post(mux, "u1", `{"message":" Sidebar froze ","email":"me@example.com","appVersion":"0.1.0","osVersion":"macOS 26.1","logs":"line1\nline2"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d %s", rec.Code, rec.Body)
	}
	var res struct{ ID string }
	_ = json.Unmarshal(rec.Body.Bytes(), &res)

	data, err := os.ReadFile(filepath.Join(dir, res.ID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var rep Report
	if err := json.Unmarshal(data, &rep); err != nil {
		t.Fatal(err)
	}
	if rep.Message != "Sidebar froze" || rep.UserID != "u1" || rep.Email != "me@example.com" ||
		rep.AppVersion != "0.1.0" || rep.Logs != "line1\nline2" || rep.ReceivedAt.IsZero() {
		t.Fatalf("report = %+v", rep)
	}

	// Anonymous submissions are accepted too.
	if rec := post(mux, "", `{"message":"hello","appVersion":"0.1.0","osVersion":"26.1"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("anonymous status = %d", rec.Code)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("stored %d reports, want 2", len(entries))
	}
}

func TestSubmitValidation(t *testing.T) {
	_, mux := setup(t)
	tests := []struct {
		name string
		body string
		want int
	}{
		{"empty message", `{"message":"  "}`, http.StatusBadRequest},
		{"bad email", `{"message":"x","email":"nope"}`, http.StatusBadRequest},
		{"long version", `{"message":"x","appVersion":"` + strings.Repeat("9", 65) + `"}`, http.StatusBadRequest},
		{"too large", `{"message":"x","logs":"` + strings.Repeat("a", 2<<20) + `"}`, http.StatusRequestEntityTooLarge},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if rec := post(mux, "u-"+tt.name, tt.body); rec.Code != tt.want {
				t.Fatalf("status = %d, want %d", rec.Code, tt.want)
			}
		})
	}
}

func TestSubmitRateLimited(t *testing.T) {
	_, mux := setup(t)
	var last *httptest.ResponseRecorder
	for range 11 {
		last = post(mux, "", `{"message":"spam"}`)
	}
	if last.Code != http.StatusTooManyRequests {
		t.Fatalf("11th submission = %d", last.Code)
	}
	if rec := post(mux, "someone", `{"message":"legit"}`); rec.Code != http.StatusAccepted {
		t.Fatalf("authenticated user limited by anonymous traffic: %d", rec.Code)
	}
}
