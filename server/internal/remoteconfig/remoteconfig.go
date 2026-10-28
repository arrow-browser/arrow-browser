// Package remoteconfig replaces LaunchDarkly feature flags and the
// content.arc.net behavior files with a single JSON document read from
// <data-dir>/config/*.json, falling back to built-in defaults.
package remoteconfig

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
)

var defaultWebContentBehavior = json.RawMessage(`{"keepaliveAllowList":[` +
	`{"urlRegex":"^https://mail\\.google\\.com/mail"},` +
	`{"urlRegex":"^https://calendar\\.google\\.com/calendar"},` +
	`{"urlRegex":"^https://app\\.slack\\.com/client"},` +
	`{"urlRegex":"^https://(www\\.)?notion\\.so"},` +
	`{"urlRegex":"^https://linear\\.app"},` +
	`{"urlRegex":"^https://open\\.spotify\\.com"},` +
	`{"urlRegex":"^https://web\\.whatsapp\\.com"}]}`)

var defaultCommandBarBehavior = json.RawMessage(`{"dedupByTitleAndHostList":[` +
	`"figma.com","maps.google.com","notion.so","app.notion.com","zoom.us",` +
	`"opentable.com","zillow.com","github.com","app.mode.com","console.cloud.google.com"]}`)

var defaultMemoryBehavior = json.RawMessage(`{"tabDiscardAfterMinutes":60,"archiveAfterHours":12}`)

// Handler serves GET /v1/config.
type Handler struct {
	dir    string
	logger *slog.Logger
	flags  json.RawMessage
}

// New reads overrides from dir. aiEnabled seeds the default aiFeatures flag
// so clients hide AI features when the server has no Anthropic API key.
func New(dir string, aiEnabled bool, logger *slog.Logger) *Handler {
	flags, _ := json.Marshal(map[string]bool{"aiFeatures": aiEnabled, "sync": true, "adBlocker": true})
	return &Handler{dir: dir, logger: logger, flags: flags}
}

// Routes registers the config endpoint.
func (h *Handler) Routes(mux *http.ServeMux) {
	mux.Handle("GET /v1/config", httpx.HandlerFunc(h.serve))
}

// Document is the full remote configuration.
type Document struct {
	Flags              json.RawMessage `json:"flags"`
	CommandBarBehavior json.RawMessage `json:"commandBarBehavior"`
	MemoryBehavior     json.RawMessage `json:"memoryBehavior"`
	WebContentBehavior json.RawMessage `json:"webContentBehavior"`
}

// Load builds the configuration. Files are re-read on every call so edits
// apply without a restart; they are tiny.
func (h *Handler) Load() Document {
	return Document{
		Flags:              h.read("flags.json", h.flags),
		CommandBarBehavior: h.read("command_bar_behavior.json", defaultCommandBarBehavior),
		MemoryBehavior:     h.read("memory_behavior.json", defaultMemoryBehavior),
		WebContentBehavior: h.read("web_content_behavior.json", defaultWebContentBehavior),
	}
}

// read returns the override file if it holds a JSON object, else the default.
func (h *Handler) read(file string, fallback json.RawMessage) json.RawMessage {
	path := filepath.Join(h.dir, file)
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return fallback
	}
	if err != nil {
		h.logger.Warn("config: cannot read override, using default", "file", path, "err", err)
		return fallback
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err != nil || obj == nil {
		h.logger.Warn("config: override is not a JSON object, using default", "file", path)
		return fallback
	}
	var compact bytes.Buffer
	_ = json.Compact(&compact, data)
	return compact.Bytes()
}

func (h *Handler) serve(w http.ResponseWriter, r *http.Request) error {
	body, err := json.Marshal(h.Load())
	if err != nil {
		return err
	}
	etag := httpx.StrongETag(body)
	w.Header().Set("ETag", etag)
	w.Header().Set("Cache-Control", "no-cache")
	if httpx.NotModified(r, etag) {
		w.WriteHeader(http.StatusNotModified)
		return nil
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, err = w.Write(body)
	return err
}
