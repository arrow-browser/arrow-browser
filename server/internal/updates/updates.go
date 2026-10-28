// Package updates replaces the releases.arc.net Sparkle feed. It renders a
// Sparkle 2 appcast from <data-dir>/releases/releases.json.
package updates

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"time"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
)

// Release is one entry of releases.json. List newest first.
type Release struct {
	Version              string    `json:"version"`      // CFBundleVersion
	ShortVersion         string    `json:"shortVersion"` // CFBundleShortVersionString
	URL                  string    `json:"url"`
	Length               int64     `json:"length"`
	EdSignature          string    `json:"edSignature"`
	MinimumSystemVersion string    `json:"minimumSystemVersion"`
	ReleaseNotesHTML     string    `json:"releaseNotesHTML"`
	PubDate              time.Time `json:"pubDate"`
}

// Handler serves the appcast.
type Handler struct {
	path      string
	publicURL string
}

// New reads releases from path.
func New(path, publicURL string) *Handler {
	return &Handler{path: path, publicURL: publicURL}
}

// Routes registers the appcast endpoint.
func (h *Handler) Routes(mux *http.ServeMux) {
	mux.Handle("GET /v1/updates/appcast.xml", httpx.HandlerFunc(h.serve))
}

func (h *Handler) releases() ([]Release, error) {
	data, err := os.ReadFile(h.path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var releases []Release
	if err := json.Unmarshal(data, &releases); err != nil {
		return nil, fmt.Errorf("updates: decode %s: %w", h.path, err)
	}
	return releases, nil
}

func (h *Handler) serve(w http.ResponseWriter, r *http.Request) error {
	releases, err := h.releases()
	if err != nil {
		return err
	}
	body, err := Appcast(releases, h.publicURL+"/v1/updates/appcast.xml")
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/rss+xml; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, err = w.Write(body)
	return err
}

// Sparkle element names are written with their namespace prefix verbatim;
// encoding/xml would otherwise emit a fresh xmlns on every element.
type rss struct {
	XMLName xml.Name `xml:"rss"`
	Version string   `xml:"version,attr"`
	Sparkle string   `xml:"xmlns:sparkle,attr"`
	DC      string   `xml:"xmlns:dc,attr"`
	Channel channel  `xml:"channel"`
}

type channel struct {
	Title       string `xml:"title"`
	Link        string `xml:"link"`
	Description string `xml:"description"`
	Language    string `xml:"language"`
	Items       []item `xml:"item"`
}

type item struct {
	Title                string    `xml:"title"`
	PubDate              string    `xml:"pubDate,omitempty"`
	Version              string    `xml:"sparkle:version"`
	ShortVersionString   string    `xml:"sparkle:shortVersionString,omitempty"`
	MinimumSystemVersion string    `xml:"sparkle:minimumSystemVersion,omitempty"`
	Description          *cdata    `xml:"description,omitempty"`
	Enclosure            enclosure `xml:"enclosure"`
}

type cdata struct {
	Text string `xml:",cdata"`
}

type enclosure struct {
	URL         string `xml:"url,attr"`
	Length      int64  `xml:"length,attr"`
	Type        string `xml:"type,attr"`
	EdSignature string `xml:"sparkle:edSignature,attr,omitempty"`
}

// Appcast renders releases as a Sparkle 2 RSS feed.
func Appcast(releases []Release, link string) ([]byte, error) {
	feed := rss{
		Version: "2.0",
		Sparkle: "http://www.andymatuschak.org/xml-namespaces/sparkle",
		DC:      "http://purl.org/dc/elements/1.1/",
		Channel: channel{
			Title:       "Arrow",
			Link:        link,
			Description: "Arrow browser updates",
			Language:    "en",
			Items:       []item{},
		},
	}
	for _, rel := range releases {
		title := rel.ShortVersion
		if title == "" {
			title = rel.Version
		}
		it := item{
			Title:                "Version " + title,
			Version:              rel.Version,
			ShortVersionString:   rel.ShortVersion,
			MinimumSystemVersion: rel.MinimumSystemVersion,
			Enclosure: enclosure{
				URL:         rel.URL,
				Length:      rel.Length,
				Type:        "application/octet-stream",
				EdSignature: rel.EdSignature,
			},
		}
		if !rel.PubDate.IsZero() {
			it.PubDate = rel.PubDate.UTC().Format(time.RFC1123Z)
		}
		if rel.ReleaseNotesHTML != "" {
			it.Description = &cdata{Text: rel.ReleaseNotesHTML}
		}
		feed.Channel.Items = append(feed.Channel.Items, it)
	}
	out, err := xml.MarshalIndent(feed, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), append(out, '\n')...), nil
}
