package remoteconfig

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func get(t *testing.T, h *Handler, etag string) *httptest.ResponseRecorder {
	t.Helper()
	mux := http.NewServeMux()
	h.Routes(mux)
	req := httptest.NewRequest(http.MethodGet, "/v1/config", nil)
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

func TestDefaults(t *testing.T) {
	h := New(t.TempDir(), false, slog.New(slog.DiscardHandler))
	rec := get(t, h, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var doc struct {
		Flags              map[string]bool `json:"flags"`
		CommandBarBehavior struct {
			DedupByTitleAndHostList []string `json:"dedupByTitleAndHostList"`
		} `json:"commandBarBehavior"`
		MemoryBehavior     map[string]int `json:"memoryBehavior"`
		WebContentBehavior struct {
			KeepaliveAllowList []struct{ URLRegex string } `json:"keepaliveAllowList"`
		} `json:"webContentBehavior"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Flags["aiFeatures"] || !doc.Flags["sync"] || !doc.Flags["adBlocker"] {
		t.Fatalf("flags = %v (aiFeatures must follow AI availability)", doc.Flags)
	}
	if len(doc.CommandBarBehavior.DedupByTitleAndHostList) == 0 || doc.CommandBarBehavior.DedupByTitleAndHostList[0] != "figma.com" {
		t.Fatalf("commandBarBehavior = %+v", doc.CommandBarBehavior)
	}
	if doc.MemoryBehavior["tabDiscardAfterMinutes"] != 60 || doc.MemoryBehavior["archiveAfterHours"] != 12 {
		t.Fatalf("memoryBehavior = %v", doc.MemoryBehavior)
	}
	if len(doc.WebContentBehavior.KeepaliveAllowList) == 0 {
		t.Fatal("webContentBehavior default is empty")
	}
}

func TestOverridesAndETag(t *testing.T) {
	dir := t.TempDir()
	h := New(dir, true, slog.New(slog.DiscardHandler))

	first := get(t, h, "")
	etag := first.Header().Get("ETag")
	if etag == "" {
		t.Fatal("missing ETag")
	}
	if rec := get(t, h, etag); rec.Code != http.StatusNotModified || rec.Body.Len() != 0 {
		t.Fatalf("conditional GET = %d, body %q", rec.Code, rec.Body)
	}

	if err := os.WriteFile(filepath.Join(dir, "flags.json"), []byte(`{ "aiFeatures": false, "beta": true }`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "memory_behavior.json"), []byte(`[1,2,3]`), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := get(t, h, etag)
	if rec.Code != http.StatusOK {
		t.Fatalf("status after override = %d", rec.Code)
	}
	if rec.Header().Get("ETag") == etag {
		t.Fatal("ETag did not change with content")
	}
	var doc struct {
		Flags          map[string]bool `json:"flags"`
		MemoryBehavior map[string]int  `json:"memoryBehavior"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Flags["aiFeatures"] || !doc.Flags["beta"] || len(doc.Flags) != 2 {
		t.Fatalf("flags override not applied: %v", doc.Flags)
	}
	if doc.MemoryBehavior["tabDiscardAfterMinutes"] != 60 {
		t.Fatalf("invalid override should fall back to default, got %v", doc.MemoryBehavior)
	}
}
