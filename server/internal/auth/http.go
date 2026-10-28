package auth

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
	"github.com/euskadi31/arrow-browser/server/internal/ratelimit"
)

const maxAuthBody = 64 << 10

type ctxKey struct{}

type principal struct {
	user        User
	tokenDigest string
}

// WithUser returns a context carrying user as the authenticated principal.
// The middleware uses it; tests of other packages can use it directly.
func WithUser(ctx context.Context, user User) context.Context {
	return context.WithValue(ctx, ctxKey{}, principal{user: user})
}

// FromContext returns the authenticated user, if any.
func FromContext(ctx context.Context) (User, bool) {
	p, ok := ctx.Value(ctxKey{}).(principal)
	return p.user, ok
}

// Require rejects requests without a valid bearer token with 401.
func (s *Service) Require(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			w.Header().Set("WWW-Authenticate", "Bearer")
			httpx.WriteError(w, http.StatusUnauthorized, "unauthorized", "missing bearer token")
			return
		}
		user, err := s.Authenticate(token)
		if err != nil {
			w.Header().Set("WWW-Authenticate", `Bearer error="invalid_token"`)
			httpx.WriteErr(w, r, err)
			return
		}
		ctx := context.WithValue(r.Context(), ctxKey{}, principal{user: user, tokenDigest: hashToken(token)})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Optional attaches the user when a valid token is present and otherwise
// lets the request through anonymously.
func (s *Service) Optional(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token, ok := bearerToken(r); ok {
			if user, err := s.Authenticate(token); err == nil {
				r = r.WithContext(WithUser(r.Context(), user))
			}
		}
		next.ServeHTTP(w, r)
	})
}

func bearerToken(r *http.Request) (string, bool) {
	scheme, token, ok := strings.Cut(r.Header.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

// Routes registers the account endpoints. Credential endpoints are rate
// limited per client IP to slow down online password guessing.
func (s *Service) Routes(mux *http.ServeMux) {
	attempts := ratelimit.New(20, time.Minute)
	limited := func(h httpx.HandlerFunc) http.Handler {
		return httpx.HandlerFunc(func(w http.ResponseWriter, r *http.Request) error {
			if ok, wait := attempts.Allow(httpx.ClientIP(r)); !ok {
				w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
				return httpx.NewError(http.StatusTooManyRequests, "rate_limited", "too many attempts, retry later")
			}
			return h(w, r)
		})
	}
	mux.Handle("POST /v1/auth/register", limited(s.handleRegister))
	mux.Handle("POST /v1/auth/login", limited(s.handleLogin))
	mux.Handle("POST /v1/auth/logout", s.Require(httpx.HandlerFunc(s.handleLogout)))
	mux.Handle("GET /v1/me", s.Require(httpx.HandlerFunc(s.handleMe)))
}

type sessionResponse struct {
	Token string `json:"token"`
	User  User   `json:"user"`
}

func (s *Service) handleRegister(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email       string `json:"email"`
		Password    string `json:"password"`
		DisplayName string `json:"displayName"`
	}
	if err := httpx.DecodeJSON(w, r, &req, maxAuthBody); err != nil {
		return err
	}
	token, user, err := s.Register(req.Email, req.Password, req.DisplayName)
	if err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusCreated, sessionResponse{Token: token, User: user})
	return nil
}

func (s *Service) handleLogin(w http.ResponseWriter, r *http.Request) error {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := httpx.DecodeJSON(w, r, &req, maxAuthBody); err != nil {
		return err
	}
	token, user, err := s.Login(req.Email, req.Password)
	if err != nil {
		return err
	}
	httpx.WriteJSON(w, http.StatusOK, sessionResponse{Token: token, User: user})
	return nil
}

func (s *Service) handleLogout(w http.ResponseWriter, r *http.Request) error {
	p, _ := r.Context().Value(ctxKey{}).(principal)
	if err := s.revoke(p.tokenDigest); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Service) handleMe(w http.ResponseWriter, r *http.Request) error {
	user, _ := FromContext(r.Context())
	httpx.WriteJSON(w, http.StatusOK, map[string]User{"user": user})
	return nil
}
