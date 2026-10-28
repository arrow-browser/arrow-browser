package updates

import (
	"encoding/xml"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

// parsed mirrors the feed using real namespace resolution, the way Sparkle
// reads it.
type parsed struct {
	Channel struct {
		Title string `xml:"title"`
		Items []struct {
			Title       string `xml:"title"`
			PubDate     string `xml:"pubDate"`
			Version     string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle version"`
			Short       string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle shortVersionString"`
			MinSystem   string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle minimumSystemVersion"`
			Description string `xml:"description"`
			Enclosure   struct {
				URL       string `xml:"url,attr"`
				Length    int64  `xml:"length,attr"`
				Type      string `xml:"type,attr"`
				Signature string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle edSignature,attr"`
			} `xml:"enclosure"`
		} `xml:"item"`
	} `xml:"channel"`
}

func fetch(t *testing.T, dir string) (*httptest.ResponseRecorder, parsed) {
	t.Helper()
	mux := http.NewServeMux()
	New(filepath.Join(dir, "releases.json"), "https://arrow.example").Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/updates/appcast.xml", nil))
	var feed parsed
	if rec.Code == http.StatusOK {
		if err := xml.Unmarshal(rec.Body.Bytes(), &feed); err != nil {
			t.Fatalf("invalid XML: %v\n%s", err, rec.Body)
		}
	}
	return rec, feed
}

func TestEmptyFeed(t *testing.T) {
	rec, feed := fetch(t, t.TempDir())
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if !strings.HasPrefix(rec.Header().Get("Content-Type"), "application/rss+xml") {
		t.Fatalf("Content-Type = %q", rec.Header().Get("Content-Type"))
	}
	if feed.Channel.Title != "Arrow" || len(feed.Channel.Items) != 0 {
		t.Fatalf("feed = %+v", feed)
	}
	if !strings.Contains(rec.Body.String(), `xmlns:sparkle="`+sparkleNS+`"`) {
		t.Fatal("missing sparkle namespace declaration")
	}
}

func TestFeedWithReleases(t *testing.T) {
	dir := t.TempDir()
	releases := `[
	  {"version":"120","shortVersion":"1.2.0","url":"https://dl.example/Arrow-1.2.0.zip","length":12345,
	   "edSignature":"c2lnbmF0dXJl","minimumSystemVersion":"14.0",
	   "releaseNotesHTML":"<h2>New</h2><p>Split view ]]> fixes</p>","pubDate":"2026-10-01T12:00:00Z"},
	  {"version":"110","url":"https://dl.example/Arrow-1.1.0.zip","length":999}
	]`
	if err := os.WriteFile(filepath.Join(dir, "releases.json"), []byte(releases), 0o600); err != nil {
		t.Fatal(err)
	}
	rec, feed := fetch(t, dir)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	if len(feed.Channel.Items) != 2 {
		t.Fatalf("items = %d\n%s", len(feed.Channel.Items), rec.Body)
	}
	it := feed.Channel.Items[0]
	if it.Title != "Version 1.2.0" || it.Version != "120" || it.Short != "1.2.0" || it.MinSystem != "14.0" {
		t.Fatalf("item = %+v", it)
	}
	if it.PubDate != "Thu, 01 Oct 2026 12:00:00 +0000" {
		t.Fatalf("pubDate = %q", it.PubDate)
	}
	if it.Description != "<h2>New</h2><p>Split view ]]> fixes</p>" {
		t.Fatalf("description = %q", it.Description)
	}
	if it.Enclosure.URL != "https://dl.example/Arrow-1.2.0.zip" || it.Enclosure.Length != 12345 ||
		it.Enclosure.Signature != "c2lnbmF0dXJl" || it.Enclosure.Type != "application/octet-stream" {
		t.Fatalf("enclosure = %+v", it.Enclosure)
	}
	if second := feed.Channel.Items[1]; second.Title != "Version 110" || second.PubDate != "" || second.Description != "" {
		t.Fatalf("second item = %+v", second)
	}
}

func TestInvalidReleasesFile(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "releases.json"), []byte("{oops"), 0o600)
	if rec, _ := fetch(t, dir); rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", rec.Code)
	}
}
