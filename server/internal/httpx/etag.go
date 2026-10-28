package httpx

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
)

// StrongETag returns a quoted strong ETag derived from the SHA-256 of data.
func StrongETag(data []byte) string {
	sum := sha256.Sum256(data)
	return `"` + hex.EncodeToString(sum[:16]) + `"`
}

// NotModified reports whether the request's If-None-Match header matches
// etag (weak comparison, as RFC 9110 requires for If-None-Match).
func NotModified(r *http.Request, etag string) bool {
	header := r.Header.Get("If-None-Match")
	if header == "" {
		return false
	}
	want := strings.TrimPrefix(etag, "W/")
	for candidate := range strings.SplitSeq(header, ",") {
		candidate = strings.TrimSpace(candidate)
		if candidate == "*" || strings.TrimPrefix(candidate, "W/") == want {
			return true
		}
	}
	return false
}
