package blocklist

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const publicURL = "https://arrow.example"

func newTestMux(s *Service) *http.ServeMux {
	mux := http.NewServeMux()
	s.Routes(mux)
	return mux
}

func get(h http.Handler, path string, header map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	for k, v := range header {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func sha(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

func TestManifestAndServe(t *testing.T) {
	dir := t.TempDir()
	const easylist = "[Adblock Plus 2.0]\n||ads.example^\n"
	for name, content := range map[string]string{
		"easylist.txt": easylist,
		"custom.txt":   "||tracker.example^\n",
		"README.md":    "ignored",
		"Bad Name.txt": "ignored",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mux := newTestMux(New(dir, publicURL, slog.New(slog.DiscardHandler)))

	rec := get(mux, "/v1/blocklists/manifest.json", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("manifest status = %d", rec.Code)
	}
	var manifest struct{ Lists []List }
	if err := json.Unmarshal(rec.Body.Bytes(), &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Lists) != 2 || manifest.Lists[0].ID != "custom" || manifest.Lists[1].ID != "easylist" {
		t.Fatalf("manifest = %+v", manifest.Lists)
	}
	el := manifest.Lists[1]
	if el.Name != "EasyList" || el.URL != publicURL+"/v1/blocklists/easylist" || el.SHA256 != sha(easylist) ||
		el.Size != int64(len(easylist)) || el.UpdatedAt.IsZero() {
		t.Fatalf("easylist entry = %+v", el)
	}

	rec = get(mux, "/v1/blocklists/easylist", nil)
	if rec.Code != http.StatusOK || rec.Body.String() != easylist {
		t.Fatalf("list = %d %q", rec.Code, rec.Body)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
		t.Fatalf("Content-Type = %q", ct)
	}
	etag := rec.Header().Get("ETag")
	if etag != `"`+sha(easylist)+`"` {
		t.Fatalf("ETag = %q", etag)
	}
	if rec := get(mux, "/v1/blocklists/easylist", map[string]string{"If-None-Match": etag}); rec.Code != http.StatusNotModified {
		t.Fatalf("conditional GET = %d", rec.Code)
	}

	for _, path := range []string{"/v1/blocklists/missing", "/v1/blocklists/..%2Fsecret", "/v1/blocklists/README"} {
		if rec := get(mux, path, nil); rec.Code != http.StatusNotFound {
			t.Errorf("%s = %d, want 404", path, rec.Code)
		}
	}
}

func TestManifestWithoutDirectory(t *testing.T) {
	s := New(filepath.Join(t.TempDir(), "missing"), publicURL, slog.New(slog.DiscardHandler))
	rec := get(newTestMux(s), "/v1/blocklists/manifest.json", nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "{\"lists\":[]}\n" {
		t.Fatalf("manifest = %d %q", rec.Code, rec.Body)
	}
}

func TestManifestHashTracksChanges(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "x.txt")
	s := New(dir, publicURL, slog.New(slog.DiscardHandler))
	_ = os.WriteFile(path, []byte("one"), 0o644)
	first, _ := s.Manifest()
	_ = os.WriteFile(path, []byte("two!"), 0o644)
	later := time.Now().Add(time.Minute)
	_ = os.Chtimes(path, later, later)
	second, _ := s.Manifest()
	if first[0].SHA256 == second[0].SHA256 || second[0].SHA256 != sha("two!") {
		t.Fatal("manifest hash not updated after file change")
	}
}

func TestRefresh(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/good.txt":
			io.WriteString(w, "||ads.example^\n")
		default:
			http.Error(w, "gone", http.StatusNotFound)
		}
	}))
	defer upstream.Close()

	dir := t.TempDir()
	s := New(dir, publicURL, slog.New(slog.DiscardHandler))
	err := s.Refresh(context.Background(), []Source{
		{ID: "good", URL: upstream.URL + "/good.txt"},
		{ID: "bad", URL: upstream.URL + "/bad.txt"},
	})
	if err == nil {
		t.Fatal("expected error for failing source")
	}
	data, readErr := os.ReadFile(filepath.Join(dir, "good.txt"))
	if readErr != nil || string(data) != "||ads.example^\n" {
		t.Fatalf("good list = %q, %v", data, readErr)
	}
	if _, err := os.Stat(filepath.Join(dir, "bad.txt")); !os.IsNotExist(err) {
		t.Fatal("failed download must not create a file")
	}
}
