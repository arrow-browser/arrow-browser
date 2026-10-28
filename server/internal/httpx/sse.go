package httpx

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// SSE writes a text/event-stream response. Headers are sent lazily on the
// first event so callers can still answer with a JSON error before that.
type SSE struct {
	w       http.ResponseWriter
	rc      *http.ResponseController
	started bool
}

// NewSSE prepares an event stream on w.
func NewSSE(w http.ResponseWriter) *SSE {
	return &SSE{w: w, rc: http.NewResponseController(w)}
}

// Started reports whether the response headers have been sent.
func (s *SSE) Started() bool { return s.started }

func (s *SSE) start() {
	if s.started {
		return
	}
	s.started = true
	// Streams outlive the server-wide write timeout.
	_ = s.rc.SetWriteDeadline(time.Time{})
	h := s.w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")
	s.w.WriteHeader(http.StatusOK)
}

// Event sends one named event whose data is v encoded as JSON, then flushes.
func (s *SSE) Event(name string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	s.start()
	if _, err := fmt.Fprintf(s.w, "event: %s\ndata: %s\n\n", name, data); err != nil {
		return err
	}
	return s.rc.Flush()
}

// Comment sends an SSE comment line (used as a keep-alive), then flushes.
func (s *SSE) Comment(text string) error {
	s.start()
	text = strings.ReplaceAll(text, "\n", " ")
	if _, err := fmt.Fprintf(s.w, ": %s\n\n", text); err != nil {
		return err
	}
	return s.rc.Flush()
}
