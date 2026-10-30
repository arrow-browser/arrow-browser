package docsync

import (
	"cmp"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/arrow-browser/arrow-browser/server/internal/auth"
	"github.com/arrow-browser/arrow-browser/server/internal/httpx"
)

// maxPushBody bounds a push request: up to maxChanges documents, but large
// payloads should be spread across several pushes.
const maxPushBody = 32 << 20

// Routes registers the sync endpoints behind requireAuth.
func (s *Service) Routes(mux *http.ServeMux, requireAuth func(http.Handler) http.Handler) {
	mux.Handle("GET /v1/sync/changes", requireAuth(httpx.HandlerFunc(s.handleChanges)))
	mux.Handle("POST /v1/sync/push", requireAuth(httpx.HandlerFunc(s.handlePush)))
	mux.Handle("GET /v1/sync/events", requireAuth(httpx.HandlerFunc(s.handleEvents)))
}

func (s *Service) handleChanges(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	var since int64
	if raw := r.URL.Query().Get("since"); raw != "" {
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || v < 0 {
			return httpx.BadRequest("since must be a non-negative integer")
		}
		since = v
	}
	rev, docs, err := s.Changes(user.ID, since)
	if err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusOK, struct {
		Revision int64      `json:"revision"`
		Changes  []Document `json:"changes"`
	}{rev, docs})
	return nil
}

func (s *Service) handlePush(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	var req struct {
		DeviceID string   `json:"deviceId"`
		Changes  []Change `json:"changes"`
	}
	if err := httpx.DecodeJSON(w, r, &req, maxPushBody); err != nil {
		return err
	}
	res, err := s.Push(user.ID, req.DeviceID, req.Changes)
	if err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusOK, res)
	return nil
}

type revisionEvent struct {
	Revision int64 `json:"revision"`
}

// handleEvents streams the user's revision: once on connect, then every
// time it changes. Clients react by calling GET /v1/sync/changes.
func (s *Service) handleEvents(w http.ResponseWriter, r *http.Request) error {
	user, _ := auth.FromContext(r.Context())
	notify, unsubscribe := s.broker.subscribe(user.ID)
	defer unsubscribe()

	last, err := s.Revision(user.ID)
	if err != nil {
		return err
	}
	sse := httpx.NewSSE(w)
	if err := sse.Event("revision", revisionEvent{last}); err != nil {
		return nil // client went away
	}
	ticker := time.NewTicker(s.keepAlive)
	defer ticker.Stop()
	for {
		select {
		case <-r.Context().Done():
			return nil
		case <-s.broker.done:
			return nil
		case <-ticker.C:
			if sse.Comment("keep-alive") != nil {
				return nil
			}
		case <-notify:
			rev, err := s.Revision(user.ID)
			if err != nil || rev == last {
				continue
			}
			last = rev
			if sse.Event("revision", revisionEvent{rev}) != nil {
				return nil
			}
		}
	}
}

// broker fans out "revision changed" signals to the event streams of a user.
// Signals carry no data and coalesce: a subscriber that is busy simply sees
// one pending signal and re-reads the current revision.
type broker struct {
	mu        sync.Mutex
	subs      map[string]map[chan struct{}]struct{}
	done      chan struct{}
	closeOnce sync.Once
}

func newBroker() *broker {
	return &broker{subs: make(map[string]map[chan struct{}]struct{}), done: make(chan struct{})}
}

func (b *broker) subscribe(userID string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	b.mu.Lock()
	if b.subs[userID] == nil {
		b.subs[userID] = make(map[chan struct{}]struct{})
	}
	b.subs[userID][ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.subs[userID], ch)
		if len(b.subs[userID]) == 0 {
			delete(b.subs, userID)
		}
		b.mu.Unlock()
	}
}

func (b *broker) notify(userID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs[userID] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

func (b *broker) close() { b.closeOnce.Do(func() { close(b.done) }) }

func sortByRevision(docs []Document) {
	slices.SortFunc(docs, func(a, b Document) int { return cmp.Compare(a.Revision, b.Revision) })
}
