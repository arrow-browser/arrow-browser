// Package httpx holds the small HTTP helpers shared by every Arrow endpoint:
// JSON encoding, the error envelope, body limits, middleware and SSE.
package httpx

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
)

// Error is an API error rendered as {"error":{"code":"...","message":"..."}}.
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("%d %s: %s", e.Status, e.Code, e.Message) }

// NewError builds an API error.
func NewError(status int, code, message string) *Error {
	return &Error{Status: status, Code: code, Message: message}
}

// BadRequest is a 400 invalid_request error.
func BadRequest(message string) *Error {
	return NewError(http.StatusBadRequest, "invalid_request", message)
}

// NotFound is a 404 not_found error.
func NotFound(message string) *Error {
	return NewError(http.StatusNotFound, "not_found", message)
}

// Unauthorized is a 401 unauthorized error.
func Unauthorized(message string) *Error {
	return NewError(http.StatusUnauthorized, "unauthorized", message)
}

// HandlerFunc is an http.HandlerFunc that may return an error. *Error values
// are rendered as-is; anything else is logged and becomes a generic 500.
type HandlerFunc func(w http.ResponseWriter, r *http.Request) error

func (h HandlerFunc) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := h(w, r); err != nil {
		WriteErr(w, r, err)
	}
}

// WriteErr renders err as a JSON error response.
func WriteErr(w http.ResponseWriter, r *http.Request, err error) {
	var apiErr *Error
	if errors.As(err, &apiErr) {
		WriteError(w, apiErr.Status, apiErr.Code, apiErr.Message)
		return
	}
	slog.ErrorContext(r.Context(), "internal error", "method", r.Method, "path", r.URL.Path, "err", err)
	WriteError(w, http.StatusInternalServerError, "internal", "internal server error")
}

// WriteError writes the JSON error envelope.
func WriteError(w http.ResponseWriter, status int, code, message string) {
	type body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	WriteJSON(w, status, map[string]body{"error": {Code: code, Message: message}})
}

// WriteJSON writes v as a JSON response with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// DecodeJSON reads at most limit bytes of JSON from the request body into dst.
func DecodeJSON(w http.ResponseWriter, r *http.Request, dst any, limit int64) error {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, limit))
	if err := dec.Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		switch {
		case errors.As(err, &maxErr):
			return NewError(http.StatusRequestEntityTooLarge, "payload_too_large",
				fmt.Sprintf("request body exceeds %d bytes", limit))
		case errors.Is(err, io.EOF):
			return BadRequest("request body is empty")
		default:
			return BadRequest("malformed JSON body")
		}
	}
	if dec.More() {
		return BadRequest("request body must contain a single JSON value")
	}
	return nil
}

// ClientIP returns the host part of the connection's remote address. Proxy
// headers are deliberately ignored because they are trivially spoofable.
func ClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
