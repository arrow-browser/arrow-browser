// Package blocklist replaces dia-blocklists: it serves the ad/tracker filter
// lists found in <data-dir>/blocklists/*.txt plus a manifest describing them,
// and can periodically refresh EasyList and EasyPrivacy from upstream.
package blocklist

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
	"github.com/euskadi31/arrow-browser/server/internal/store"
)

const maxListBytes = 64 << 20

var idPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)

// Source is an upstream list fetched by the refresher.
type Source struct {
	ID  string
	URL string
}

// DefaultSources are the lists downloaded when refreshing is enabled.
var DefaultSources = []Source{
	{ID: "easylist", URL: "https://easylist.to/easylist/easylist.txt"},
	{ID: "easyprivacy", URL: "https://easylist.to/easylist/easyprivacy.txt"},
}

var displayNames = map[string]string{"easylist": "EasyList", "easyprivacy": "EasyPrivacy"}

// List describes one list in the manifest.
type List struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	URL       string    `json:"url"`
	SHA256    string    `json:"sha256"`
	Size      int64     `json:"size"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type digest struct {
	size    int64
	modTime time.Time
	sha256  string
}

// Service serves and refreshes block lists.
type Service struct {
	dir       string
	publicURL string
	logger    *slog.Logger
	client    *http.Client

	mu     sync.Mutex
	hashes map[string]digest // cached by file name; invalidated on size/mtime change
}

// New serves lists from dir; publicURL is used to build list URLs.
func New(dir, publicURL string, logger *slog.Logger) *Service {
	return &Service{
		dir:       dir,
		publicURL: publicURL,
		logger:    logger,
		client:    &http.Client{Timeout: 2 * time.Minute},
		hashes:    make(map[string]digest),
	}
}

// Routes registers the block list endpoints.
func (s *Service) Routes(mux *http.ServeMux) {
	mux.Handle("GET /v1/blocklists/manifest.json", httpx.HandlerFunc(s.handleManifest))
	mux.Handle("GET /v1/blocklists/{id}", httpx.HandlerFunc(s.handleList))
}

// Manifest lists every valid *.txt file in the directory, sorted by ID.
func (s *Service) Manifest() ([]List, error) {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, fs.ErrNotExist) {
		return []List{}, nil
	}
	if err != nil {
		return nil, err
	}
	lists := []List{}
	for _, e := range entries {
		id, ok := strings.CutSuffix(e.Name(), ".txt")
		if !ok || !e.Type().IsRegular() || !idPattern.MatchString(id) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue // removed concurrently
		}
		sum, err := s.hash(e.Name(), info)
		if err != nil {
			return nil, err
		}
		name := displayNames[id]
		if name == "" {
			name = id
		}
		lists = append(lists, List{
			ID:        id,
			Name:      name,
			URL:       s.publicURL + "/v1/blocklists/" + id,
			SHA256:    sum,
			Size:      info.Size(),
			UpdatedAt: info.ModTime().UTC(),
		})
	}
	slices.SortFunc(lists, func(a, b List) int { return strings.Compare(a.ID, b.ID) })
	return lists, nil
}

func (s *Service) hash(name string, info fs.FileInfo) (string, error) {
	s.mu.Lock()
	cached, ok := s.hashes[name]
	s.mu.Unlock()
	if ok && cached.size == info.Size() && cached.modTime.Equal(info.ModTime()) {
		return cached.sha256, nil
	}
	f, err := os.Open(filepath.Join(s.dir, name))
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	sum := hex.EncodeToString(h.Sum(nil))
	s.mu.Lock()
	s.hashes[name] = digest{size: info.Size(), modTime: info.ModTime(), sha256: sum}
	s.mu.Unlock()
	return sum, nil
}

func (s *Service) handleManifest(w http.ResponseWriter, r *http.Request) error {
	lists, err := s.Manifest()
	if err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-cache")
	httpx.WriteJSON(w, http.StatusOK, map[string][]List{"lists": lists})
	return nil
}

func (s *Service) handleList(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if !idPattern.MatchString(id) {
		return httpx.NotFound("unknown block list")
	}
	name := id + ".txt"
	f, err := os.Open(filepath.Join(s.dir, name))
	if errors.Is(err, fs.ErrNotExist) {
		return httpx.NotFound("unknown block list")
	}
	if err != nil {
		return err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return err
	}
	sum, err := s.hash(name, info)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("ETag", `"`+sum+`"`)
	w.Header().Set("Cache-Control", "no-cache")
	// ServeContent handles If-None-Match, If-Modified-Since and Range.
	http.ServeContent(w, r, name, info.ModTime(), f)
	return nil
}

// Refresh downloads every source into the directory. A failing source does
// not prevent the others from being refreshed.
func (s *Service) Refresh(ctx context.Context, sources []Source) error {
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return err
	}
	var errs []error
	for _, src := range sources {
		if err := s.download(ctx, src); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", src.ID, err))
			continue
		}
		s.logger.Info("blocklist refreshed", "id", src.ID)
	}
	return errors.Join(errs...)
}

func (s *Service) download(ctx context.Context, src Source) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src.URL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "arrow-server")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxListBytes+1))
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > maxListBytes {
		return fmt.Errorf("list size %d out of bounds", len(data))
	}
	return store.WriteFileAtomic(filepath.Join(s.dir, src.ID+".txt"), data, 0o644)
}

// RunRefresher refreshes immediately and then every interval until ctx ends.
func (s *Service) RunRefresher(ctx context.Context, interval time.Duration, sources []Source) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		if err := s.Refresh(ctx, sources); err != nil && ctx.Err() == nil {
			s.logger.Warn("blocklist refresh failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
