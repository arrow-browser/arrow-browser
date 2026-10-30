// Package share replaces arc.net/object|easel|note|boosts and the cloud
// functions behind them: users publish a snapshot of a space, folder, easel,
// note, boost or tab, and anyone with the link can view it.
//
// Shared payloads are public by design, so unlike sync documents they are
// stored as plain JSON.
package share

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/arrow-browser/arrow-browser/server/internal/auth"
	"github.com/arrow-browser/arrow-browser/server/internal/httpx"
	"github.com/arrow-browser/arrow-browser/server/internal/store"
)

const (
	maxShareBody = 1 << 20
	maxTitleLen  = 200
	idLen        = 10
	base62       = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
)

var kinds = []string{"space", "folder", "easel", "note", "boost", "tab"}

// Share is a published object.
type Share struct {
	ID        string          `json:"id"`
	Kind      string          `json:"kind"`
	Title     string          `json:"title"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt time.Time       `json:"createdAt"`
	OwnerID   string          `json:"ownerId"`
}

type state struct {
	Shares map[string]*Share `json:"shares"`
}

// Service stores shares in a single JSON file.
type Service struct {
	db        *store.File[state]
	publicURL string
	ownerName func(userID string) string
	now       func() time.Time
}

// NewService opens the share database at path. ownerName resolves a user ID
// to the display name shown on public pages.
func NewService(path, publicURL string, ownerName func(string) string) (*Service, error) {
	db, err := store.Open[state](path)
	if err != nil {
		return nil, err
	}
	return &Service{db: db, publicURL: publicURL, ownerName: ownerName, now: time.Now}, nil
}

// Routes registers the share API and the public HTML page.
func (s *Service) Routes(mux *http.ServeMux, requireAuth func(http.Handler) http.Handler) {
	mux.Handle("POST /v1/shares", requireAuth(httpx.HandlerFunc(s.handleCreate)))
	mux.Handle("GET /v1/shares", requireAuth(httpx.HandlerFunc(s.handleListMine)))
	mux.Handle("GET /v1/shares/{id}", httpx.HandlerFunc(s.handleGet))
	mux.Handle("DELETE /v1/shares/{id}", requireAuth(httpx.HandlerFunc(s.handleDelete)))
	mux.Handle("GET /s/{id}", http.HandlerFunc(s.handlePage))
}

func (s *Service) url(id string) string { return s.publicURL + "/s/" + id }

func (s *Service) get(id string) (Share, bool) {
	var (
		sh Share
		ok bool
	)
	s.db.View(func(st *state) {
		if p, found := st.Shares[id]; found {
			sh, ok = *p, true
		}
	})
	return sh, ok
}

func (s *Service) handleCreate(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	var req struct {
		Kind    string          `json:"kind"`
		Title   string          `json:"title"`
		Payload json.RawMessage `json:"payload"`
	}
	if err := httpx.DecodeJSON(w, r, &req, maxShareBody); err != nil {
		return err
	}
	if !slices.Contains(kinds, req.Kind) {
		return httpx.BadRequest("kind must be one of " + strings.Join(kinds, ", "))
	}
	title := strings.TrimSpace(req.Title)
	if title == "" || utf8.RuneCountInString(title) > maxTitleLen || strings.ContainsFunc(title, unicode.IsControl) {
		return httpx.BadRequest("title is required (max 200 printable characters)")
	}
	if len(req.Payload) == 0 || bytes.Equal(req.Payload, []byte("null")) {
		return httpx.BadRequest("payload is required")
	}

	sh := Share{Kind: req.Kind, Title: title, Payload: req.Payload, CreatedAt: s.now().UTC(), OwnerID: user.ID}
	err := s.db.Update(func(st *state) error {
		if st.Shares == nil {
			st.Shares = make(map[string]*Share)
		}
		for {
			sh.ID = newID()
			if _, taken := st.Shares[sh.ID]; !taken {
				break
			}
		}
		st.Shares[sh.ID] = &sh
		return nil
	})
	if err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{"id": sh.ID, "url": s.url(sh.ID), "createdAt": sh.CreatedAt})
	return nil
}

type summary struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	URL       string    `json:"url"`
	CreatedAt time.Time `json:"createdAt"`
}

func (s *Service) handleListMine(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	mine := []summary{}
	s.db.View(func(st *state) {
		for _, sh := range st.Shares {
			if sh.OwnerID == user.ID {
				mine = append(mine, summary{sh.ID, sh.Kind, sh.Title, s.url(sh.ID), sh.CreatedAt})
			}
		}
	})
	slices.SortFunc(mine, func(a, b summary) int { return b.CreatedAt.Compare(a.CreatedAt) })
	httpx.WriteJSON(w, http.StatusOK, map[string][]summary{"shares": mine})
	return nil
}

type owner struct {
	DisplayName string `json:"displayName"`
}

func (s *Service) handleGet(w http.ResponseWriter, r *http.Request) error {
	sh, ok := s.get(r.PathValue("id"))
	if !ok {
		return httpx.NotFound("share not found")
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		ID        string          `json:"id"`
		Kind      string          `json:"kind"`
		Title     string          `json:"title"`
		Payload   json.RawMessage `json:"payload"`
		CreatedAt time.Time       `json:"createdAt"`
		Owner     owner           `json:"owner"`
	}{sh.ID, sh.Kind, sh.Title, sh.Payload, sh.CreatedAt, owner{s.ownerName(sh.OwnerID)}})
	return nil
}

func (s *Service) handleDelete(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	id := r.PathValue("id")
	err := s.db.Update(func(st *state) error {
		sh, ok := st.Shares[id]
		if !ok {
			return httpx.NotFound("share not found")
		}
		if sh.OwnerID != user.ID {
			return httpx.NewError(http.StatusForbidden, "forbidden", "only the owner can delete a share")
		}
		delete(st.Shares, id)
		return nil
	})
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// newID returns a random base62 string using rejection sampling, so every
// character is uniformly distributed.
func newID() string {
	id := make([]byte, 0, idLen)
	buf := make([]byte, 2*idLen)
	for len(id) < idLen {
		_, _ = rand.Read(buf)
		for _, b := range buf {
			if b < 248 && len(id) < idLen { // 248 = 4*62
				id = append(id, base62[b%62])
			}
		}
	}
	return string(id)
}
