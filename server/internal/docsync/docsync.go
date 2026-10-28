// Package docsync replaces Arc's Firestore sync. The server stores opaque,
// end-to-end encrypted documents per user and orders every change with a
// per-user revision counter; it never sees plaintext.
package docsync

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
	"github.com/euskadi31/arrow-browser/server/internal/store"
)

const (
	// MaxPayloadBytes is the maximum decoded size of one document payload.
	MaxPayloadBytes = 1 << 20
	maxChanges      = 1000
	maxDeviceIDLen  = 128
)

var (
	idPattern   = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	kindPattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._-]{0,63}$`)
)

// Document is one stored, encrypted document.
type Document struct {
	ID        string    `json:"id"`
	Kind      string    `json:"kind"`
	Payload   string    `json:"payload"`
	Deleted   bool      `json:"deleted"`
	Revision  int64     `json:"revision"`
	UpdatedAt time.Time `json:"updatedAt"`
	DeviceID  string    `json:"deviceId"`
}

// Change is one document write submitted by a device.
type Change struct {
	ID           string `json:"id"`
	Kind         string `json:"kind"`
	Payload      string `json:"payload"`
	Deleted      bool   `json:"deleted"`
	BaseRevision int64  `json:"baseRevision"`
}

// Conflict reports a change rejected because the server copy is newer.
type Conflict struct {
	ID             string `json:"id"`
	ServerRevision int64  `json:"serverRevision"`
}

// PushResult is the outcome of a push.
type PushResult struct {
	Revision  int64      `json:"revision"`
	Accepted  []string   `json:"accepted"`
	Conflicts []Conflict `json:"conflicts"`
}

type userState struct {
	Revision int64                `json:"revision"`
	Docs     map[string]*Document `json:"docs"`
}

// Service stores documents in one JSON file per user under dir.
type Service struct {
	dir       string
	now       func() time.Time
	keepAlive time.Duration // interval between SSE keep-alive comments
	broker    *broker

	mu    sync.Mutex
	files map[string]*store.File[userState]
}

// NewService stores sync data under dir.
func NewService(dir string) *Service {
	return &Service{
		dir:       dir,
		now:       time.Now,
		keepAlive: 25 * time.Second,
		broker:    newBroker(),
		files:     make(map[string]*store.File[userState]),
	}
}

// Close ends every open event stream; used on shutdown.
func (s *Service) Close() { s.broker.close() }

// userFile returns the store for userID. IDs are server-generated hex
// strings, so they are safe to use as file names.
func (s *Service) userFile(userID string) (*store.File[userState], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if f, ok := s.files[userID]; ok {
		return f, nil
	}
	f, err := store.Open[userState](filepath.Join(s.dir, userID+".json"))
	if err != nil {
		return nil, err
	}
	s.files[userID] = f
	return f, nil
}

// Revision returns the user's current revision.
func (s *Service) Revision(userID string) (int64, error) {
	f, err := s.userFile(userID)
	if err != nil {
		return 0, err
	}
	var rev int64
	f.View(func(st *userState) { rev = st.Revision })
	return rev, nil
}

// Changes returns every document with a revision greater than since,
// ordered by revision, plus the current revision.
func (s *Service) Changes(userID string, since int64) (int64, []Document, error) {
	f, err := s.userFile(userID)
	if err != nil {
		return 0, nil, err
	}
	var (
		rev  int64
		docs = []Document{}
	)
	f.View(func(st *userState) {
		rev = st.Revision
		for _, d := range st.Docs {
			if d.Revision > since {
				docs = append(docs, *d)
			}
		}
	})
	sortByRevision(docs)
	return rev, docs, nil
}

// Push applies changes with per-document optimistic concurrency: a change
// whose baseRevision is older than the stored document is reported as a
// conflict and not applied. Each accepted change gets the next revision.
func (s *Service) Push(userID, deviceID string, changes []Change) (PushResult, error) {
	if err := validatePush(deviceID, changes); err != nil {
		return PushResult{}, err
	}
	f, err := s.userFile(userID)
	if err != nil {
		return PushResult{}, err
	}
	res := PushResult{Accepted: []string{}, Conflicts: []Conflict{}}
	now := s.now().UTC()
	err = f.Update(func(st *userState) error {
		if st.Docs == nil {
			st.Docs = make(map[string]*Document)
		}
		for _, c := range changes {
			if cur, ok := st.Docs[c.ID]; ok && cur.Revision > c.BaseRevision {
				res.Conflicts = append(res.Conflicts, Conflict{ID: c.ID, ServerRevision: cur.Revision})
				continue
			}
			st.Revision++
			payload := c.Payload
			if c.Deleted {
				payload = "" // tombstones keep no content
			}
			st.Docs[c.ID] = &Document{
				ID: c.ID, Kind: c.Kind, Payload: payload, Deleted: c.Deleted,
				Revision: st.Revision, UpdatedAt: now, DeviceID: deviceID,
			}
			res.Accepted = append(res.Accepted, c.ID)
		}
		res.Revision = st.Revision
		if len(res.Accepted) == 0 {
			return store.ErrNoChange
		}
		return nil
	})
	if err != nil {
		return PushResult{}, err
	}
	if len(res.Accepted) > 0 {
		s.broker.notify(userID)
	}
	return res, nil
}

func validatePush(deviceID string, changes []Change) error {
	if deviceID == "" || len(deviceID) > maxDeviceIDLen {
		return httpx.BadRequest("deviceId is required (max 128 characters)")
	}
	if len(changes) == 0 || len(changes) > maxChanges {
		return httpx.BadRequest(fmt.Sprintf("changes must contain between 1 and %d entries", maxChanges))
	}
	for i, c := range changes {
		if !idPattern.MatchString(c.ID) {
			return httpx.BadRequest(fmt.Sprintf("changes[%d].id must match %s", i, idPattern))
		}
		if !kindPattern.MatchString(c.Kind) {
			return httpx.BadRequest(fmt.Sprintf("changes[%d].kind must match %s", i, kindPattern))
		}
		if c.BaseRevision < 0 {
			return httpx.BadRequest(fmt.Sprintf("changes[%d].baseRevision must be >= 0", i))
		}
		if c.Deleted {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(c.Payload)
		if err != nil {
			return httpx.BadRequest(fmt.Sprintf("changes[%d].payload must be standard base64", i))
		}
		if len(decoded) > MaxPayloadBytes {
			return httpx.NewError(http.StatusRequestEntityTooLarge, "payload_too_large", fmt.Sprintf("changes[%d].payload exceeds %d bytes", i, MaxPayloadBytes))
		}
	}
	return nil
}
