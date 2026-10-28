// Package feedback replaces Arc's bug-report endpoint. Reports are sent only
// when the user explicitly submits them and are stored as JSON files; there
// is no analytics or telemetry.
package feedback

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/mail"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/euskadi31/arrow-browser/server/internal/auth"
	"github.com/euskadi31/arrow-browser/server/internal/httpx"
	"github.com/euskadi31/arrow-browser/server/internal/ratelimit"
	"github.com/euskadi31/arrow-browser/server/internal/store"
)

const (
	maxBody       = 2 << 20
	maxMessageLen = 20_000
	maxVersionLen = 64
)

// Report is one stored feedback submission.
type Report struct {
	ID         string    `json:"id"`
	ReceivedAt time.Time `json:"receivedAt"`
	UserID     string    `json:"userId,omitempty"`
	Message    string    `json:"message"`
	Email      string    `json:"email,omitempty"`
	AppVersion string    `json:"appVersion"`
	OSVersion  string    `json:"osVersion"`
	Logs       string    `json:"logs,omitempty"`
}

// Handler stores feedback under dir.
type Handler struct {
	dir     string
	now     func() time.Time
	limiter *ratelimit.Limiter
}

// New stores reports in dir. Submissions are limited to 10 per hour per
// user (or per IP when anonymous) to keep the disk from being filled.
func New(dir string) *Handler {
	return &Handler{dir: dir, now: time.Now, limiter: ratelimit.New(10, time.Hour)}
}

// Routes registers the feedback endpoint; optionalAuth attaches the user
// when a valid token is sent.
func (h *Handler) Routes(mux *http.ServeMux, optionalAuth func(http.Handler) http.Handler) {
	mux.Handle("POST /v1/feedback", optionalAuth(httpx.HandlerFunc(h.handleSubmit)))
}

func (h *Handler) handleSubmit(w http.ResponseWriter, r *http.Request) error {
	user, authed := auth.FromContext(r.Context())
	key := "ip:" + httpx.ClientIP(r)
	if authed {
		key = "user:" + user.ID
	}
	if ok, wait := h.limiter.Allow(key); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		return httpx.NewError(http.StatusTooManyRequests, "rate_limited", "too much feedback, retry later")
	}

	var req struct {
		Message    string `json:"message"`
		Email      string `json:"email"`
		AppVersion string `json:"appVersion"`
		OSVersion  string `json:"osVersion"`
		Logs       string `json:"logs"`
	}
	if err := httpx.DecodeJSON(w, r, &req, maxBody); err != nil {
		return err
	}
	msg := strings.TrimSpace(req.Message)
	if msg == "" || utf8.RuneCountInString(msg) > maxMessageLen {
		return httpx.BadRequest("message is required (max 20000 characters)")
	}
	email := strings.TrimSpace(req.Email)
	if email != "" {
		if addr, err := mail.ParseAddress(email); err != nil || addr.Address != email {
			return httpx.BadRequest("email is not a valid address")
		}
	}
	if len(req.AppVersion) > maxVersionLen || len(req.OSVersion) > maxVersionLen {
		return httpx.BadRequest("appVersion and osVersion must be at most 64 characters")
	}

	now := h.now().UTC()
	rep := Report{
		ID:         now.Format("20060102T150405Z") + "-" + randomHex(6),
		ReceivedAt: now,
		Message:    msg,
		Email:      email,
		AppVersion: req.AppVersion,
		OSVersion:  req.OSVersion,
		Logs:       req.Logs,
	}
	if authed {
		rep.UserID = user.ID
	}
	data, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(h.dir, 0o700); err != nil {
		return err
	}
	if err := store.WriteFileAtomic(filepath.Join(h.dir, rep.ID+".json"), data, 0o600); err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusAccepted, map[string]string{"id": rep.ID})
	return nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
