package docsync

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/arrow-browser/arrow-browser/server/internal/auth"
)

// fakeAuth authenticates "Bearer <userID>" as that user.
func fakeAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if id == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithUser(r.Context(), auth.User{ID: id})))
	})
}

func newTestServer(t *testing.T) (*Service, *httptest.Server) {
	t.Helper()
	s := NewService(t.TempDir())
	mux := http.NewServeMux()
	s.Routes(mux, fakeAuth)
	srv := httptest.NewServer(mux)
	t.Cleanup(func() {
		s.Close()
		srv.Close()
	})
	return s, srv
}

func call(t *testing.T, srv *httptest.Server, method, path, user string, body any, out any) int {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, srv.URL+path, &buf)
	req.Header.Set("Authorization", "Bearer "+user)
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil && resp.StatusCode < 300 {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			t.Fatal(err)
		}
	}
	return resp.StatusCode
}

func enc(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

type changesResponse struct {
	Revision int64      `json:"revision"`
	Changes  []Document `json:"changes"`
}

func TestPushAndChanges(t *testing.T) {
	_, srv := newTestServer(t)

	var empty changesResponse
	if code := call(t, srv, http.MethodGet, "/v1/sync/changes", "u1", nil, &empty); code != 200 {
		t.Fatalf("changes status = %d", code)
	}
	if empty.Revision != 0 || empty.Changes == nil || len(empty.Changes) != 0 {
		t.Fatalf("empty changes = %+v (changes must be [] not null)", empty)
	}

	var push PushResult
	code := call(t, srv, http.MethodPost, "/v1/sync/push", "u1", map[string]any{
		"deviceId": "mac-1",
		"changes": []Change{
			{ID: "space-1", Kind: "space", Payload: enc("cipher-a")},
			{ID: "item-1", Kind: "item", Payload: enc("cipher-b")},
		},
	}, &push)
	if code != 200 {
		t.Fatalf("push status = %d", code)
	}
	if push.Revision != 2 || len(push.Accepted) != 2 || len(push.Conflicts) != 0 {
		t.Fatalf("push = %+v", push)
	}

	var all changesResponse
	call(t, srv, http.MethodGet, "/v1/sync/changes?since=0", "u1", nil, &all)
	if all.Revision != 2 || len(all.Changes) != 2 || all.Changes[0].ID != "space-1" || all.Changes[1].Revision != 2 {
		t.Fatalf("changes = %+v", all)
	}
	if d := all.Changes[0]; d.DeviceID != "mac-1" || d.Kind != "space" || d.Payload != enc("cipher-a") || d.UpdatedAt.IsZero() {
		t.Fatalf("doc = %+v", d)
	}

	var since1 changesResponse
	call(t, srv, http.MethodGet, "/v1/sync/changes?since=1", "u1", nil, &since1)
	if len(since1.Changes) != 1 || since1.Changes[0].ID != "item-1" {
		t.Fatalf("since=1 = %+v", since1)
	}

	// Users are isolated from each other.
	var other changesResponse
	call(t, srv, http.MethodGet, "/v1/sync/changes", "u2", nil, &other)
	if other.Revision != 0 || len(other.Changes) != 0 {
		t.Fatalf("u2 sees u1 data: %+v", other)
	}
}

func TestOptimisticConcurrency(t *testing.T) {
	_, srv := newTestServer(t)
	push := func(device string, changes ...Change) PushResult {
		var res PushResult
		if code := call(t, srv, http.MethodPost, "/v1/sync/push", "u1", map[string]any{"deviceId": device, "changes": changes}, &res); code != 200 {
			t.Fatalf("push status = %d", code)
		}
		return res
	}

	push("a", Change{ID: "doc", Kind: "item", Payload: enc("v1")})                  // rev 1
	push("a", Change{ID: "doc", Kind: "item", Payload: enc("v2"), BaseRevision: 1}) // rev 2

	// Device b still believes the doc is at revision 1.
	res := push("b",
		Change{ID: "doc", Kind: "item", Payload: enc("stale"), BaseRevision: 1},
		Change{ID: "fresh", Kind: "item", Payload: enc("new")},
	)
	if len(res.Conflicts) != 1 || res.Conflicts[0] != (Conflict{ID: "doc", ServerRevision: 2}) {
		t.Fatalf("conflicts = %+v", res.Conflicts)
	}
	if len(res.Accepted) != 1 || res.Accepted[0] != "fresh" || res.Revision != 3 {
		t.Fatalf("push = %+v", res)
	}

	// An all-conflict push changes nothing.
	res = push("b", Change{ID: "doc", Kind: "item", Payload: enc("stale"), BaseRevision: 0})
	if len(res.Accepted) != 0 || res.Revision != 3 {
		t.Fatalf("push = %+v", res)
	}

	// Deleting drops the payload but keeps a tombstone with a new revision.
	res = push("b", Change{ID: "doc", Kind: "item", Deleted: true, BaseRevision: 2})
	if res.Revision != 4 {
		t.Fatalf("delete push = %+v", res)
	}
	var ch changesResponse
	call(t, srv, http.MethodGet, "/v1/sync/changes?since=3", "u1", nil, &ch)
	if len(ch.Changes) != 1 || !ch.Changes[0].Deleted || ch.Changes[0].Payload != "" || ch.Changes[0].DeviceID != "b" {
		t.Fatalf("tombstone = %+v", ch.Changes)
	}
}

func TestPushValidation(t *testing.T) {
	_, srv := newTestServer(t)
	big := base64.StdEncoding.EncodeToString(make([]byte, MaxPayloadBytes+1))
	tests := []struct {
		name string
		body map[string]any
		want int
	}{
		{"missing device", map[string]any{"changes": []Change{{ID: "a", Kind: "item", Payload: enc("x")}}}, 400},
		{"no changes", map[string]any{"deviceId": "d", "changes": []Change{}}, 400},
		{"bad id", map[string]any{"deviceId": "d", "changes": []Change{{ID: "../etc", Kind: "item", Payload: enc("x")}}}, 400},
		{"bad kind", map[string]any{"deviceId": "d", "changes": []Change{{ID: "a", Kind: "", Payload: enc("x")}}}, 400},
		{"bad base64", map[string]any{"deviceId": "d", "changes": []Change{{ID: "a", Kind: "item", Payload: "%%%"}}}, 400},
		{"negative base", map[string]any{"deviceId": "d", "changes": []Change{{ID: "a", Kind: "item", Payload: enc("x"), BaseRevision: -1}}}, 400},
		{"payload too large", map[string]any{"deviceId": "d", "changes": []Change{{ID: "a", Kind: "item", Payload: big}}}, 413},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if code := call(t, srv, http.MethodPost, "/v1/sync/push", "u1", tt.body, nil); code != tt.want {
				t.Fatalf("status = %d, want %d", code, tt.want)
			}
		})
	}
	if code := call(t, srv, http.MethodGet, "/v1/sync/changes?since=abc", "u1", nil, nil); code != 400 {
		t.Fatalf("since=abc status = %d", code)
	}
}

func TestPersistence(t *testing.T) {
	dir := t.TempDir()
	s := NewService(dir)
	if _, err := s.Push("u1", "d", []Change{{ID: "a", Kind: "item", Payload: enc("x")}}); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "u1.json"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte(`"x"`)) {
		t.Fatal("payload should be stored as base64, not decoded")
	}
	rev, docs, err := NewService(dir).Changes("u1", 0)
	if err != nil || rev != 1 || len(docs) != 1 {
		t.Fatalf("after reopen: rev=%d docs=%v err=%v", rev, docs, err)
	}
}

func TestEventsStream(t *testing.T) {
	s, srv := newTestServer(t)
	s.keepAlive = 50 * time.Millisecond

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL+"/v1/sync/events", nil)
	req.Header.Set("Authorization", "Bearer u1")
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("Content-Type = %q", ct)
	}

	lines := make(chan string, 64)
	go func() {
		sc := bufio.NewScanner(resp.Body)
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	expect := func(want string) {
		t.Helper()
		for {
			select {
			case line, ok := <-lines:
				if !ok {
					t.Fatalf("stream closed while waiting for %q", want)
				}
				if line == want {
					return
				}
			case <-ctx.Done():
				t.Fatalf("timed out waiting for %q", want)
			}
		}
	}

	expect(`data: {"revision":0}`)
	expect(": keep-alive")
	if _, err := s.Push("u1", "other-device", []Change{{ID: "a", Kind: "item", Payload: enc("x")}}); err != nil {
		t.Fatal(err)
	}
	expect("event: revision")
	expect(`data: {"revision":1}`)

	// Another user's push (u2 reaches revision 3) is not delivered to u1.
	if _, err := s.Push("u2", "d", []Change{{ID: "a", Kind: "item", Payload: enc("x")}, {ID: "b", Kind: "item", Payload: enc("y")}, {ID: "c", Kind: "item", Payload: enc("z")}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Push("u1", "d", []Change{{ID: "b", Kind: "item", Payload: enc("y")}}); err != nil {
		t.Fatal(err)
	}
	// The next data line must be u1's revision 2, not u2's revision 3.
	for line := range lines {
		if strings.HasPrefix(line, "data:") {
			if line != `data: {"revision":2}` {
				t.Fatalf("unexpected event %q", line)
			}
			break
		}
	}

	// Close ends the stream (used on graceful shutdown).
	s.Close()
	for range lines {
	}
}
