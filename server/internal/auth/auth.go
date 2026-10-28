// Package auth replaces Firebase Auth: email/password accounts and opaque
// bearer tokens. Passwords are hashed with PBKDF2-HMAC-SHA256 and tokens are
// only ever stored as SHA-256 digests.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/mail"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/euskadi31/arrow-browser/server/internal/httpx"
	"github.com/euskadi31/arrow-browser/server/internal/store"
)

// TokenTTL is how long a session token stays valid.
const TokenTTL = 90 * 24 * time.Hour

const (
	minPasswordLen    = 8
	maxPasswordBytes  = 1024
	maxDisplayNameLen = 100
	maxEmailLen       = 254
)

var (
	errEmailTaken         = httpx.NewError(http.StatusConflict, "email_taken", "an account with this email already exists")
	errInvalidCredentials = httpx.NewError(http.StatusUnauthorized, "invalid_credentials", "invalid email or password")
	errInvalidToken       = httpx.NewError(http.StatusUnauthorized, "unauthorized", "invalid or expired token")
)

// User is the public view of an account.
type User struct {
	ID          string    `json:"id"`
	Email       string    `json:"email"`
	DisplayName string    `json:"displayName"`
	CreatedAt   time.Time `json:"createdAt"`
}

type userRecord struct {
	User
	PasswordHash string `json:"passwordHash"`
}

type session struct {
	UserID    string    `json:"userId"`
	CreatedAt time.Time `json:"createdAt"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type state struct {
	Users  map[string]*userRecord `json:"users"`  // by user ID
	Emails map[string]string      `json:"emails"` // normalized email -> user ID
	Tokens map[string]*session    `json:"tokens"` // hex SHA-256 of token -> session
}

func (st *state) init() {
	if st.Users == nil {
		st.Users = make(map[string]*userRecord)
		st.Emails = make(map[string]string)
		st.Tokens = make(map[string]*session)
	}
}

// Service manages accounts and sessions.
type Service struct {
	db         *store.File[state]
	iterations int
	now        func() time.Time
	dummyHash  func() (string, error)
}

// NewService opens (or creates) the account database at path.
func NewService(path string) (*Service, error) {
	db, err := store.Open[state](path)
	if err != nil {
		return nil, err
	}
	s := &Service{db: db, iterations: DefaultIterations, now: time.Now}
	// Login with an unknown email still pays for one PBKDF2 derivation so
	// response timing does not reveal which emails are registered.
	s.dummyHash = sync.OnceValues(func() (string, error) {
		return hashPassword("arrow-timing-equalizer", s.iterations)
	})
	return s, nil
}

// Register creates an account and returns a fresh session token.
func (s *Service) Register(email, password, displayName string) (string, User, error) {
	email, ok := normalizeEmail(email)
	if !ok {
		return "", User{}, httpx.BadRequest("a valid email address is required")
	}
	if n := utf8.RuneCountInString(password); n < minPasswordLen || len(password) > maxPasswordBytes {
		return "", User{}, httpx.BadRequest("password must be between 8 and 1024 characters")
	}
	displayName = strings.TrimSpace(displayName)
	if displayName == "" {
		displayName, _, _ = strings.Cut(email, "@")
	}
	if utf8.RuneCountInString(displayName) > maxDisplayNameLen || strings.ContainsFunc(displayName, unicode.IsControl) {
		return "", User{}, httpx.BadRequest("displayName must be at most 100 printable characters")
	}

	hash, err := hashPassword(password, s.iterations)
	if err != nil {
		return "", User{}, err
	}
	now := s.now().UTC()
	user := User{ID: randomHex(16), Email: email, DisplayName: displayName, CreatedAt: now}
	token := newToken()
	err = s.db.Update(func(st *state) error {
		st.init()
		if _, exists := st.Emails[email]; exists {
			return errEmailTaken
		}
		st.Users[user.ID] = &userRecord{User: user, PasswordHash: hash}
		st.Emails[email] = user.ID
		s.addSession(st, token, user.ID, now)
		return nil
	})
	if err != nil {
		return "", User{}, err
	}
	return token, user, nil
}

// Login checks credentials and returns a fresh session token.
func (s *Service) Login(email, password string) (string, User, error) {
	email, _ = normalizeEmail(email)
	var (
		user  User
		hash  string
		found bool
	)
	s.db.View(func(st *state) {
		if id, ok := st.Emails[email]; ok {
			rec := st.Users[id]
			user, hash, found = rec.User, rec.PasswordHash, true
		}
	})
	if !found {
		dummy, err := s.dummyHash()
		if err != nil {
			return "", User{}, err
		}
		hash = dummy
	}
	match, err := verifyPassword(password, hash)
	if err != nil {
		return "", User{}, err
	}
	if !match || !found {
		return "", User{}, errInvalidCredentials
	}

	token := newToken()
	now := s.now().UTC()
	err = s.db.Update(func(st *state) error {
		st.init()
		if _, ok := st.Users[user.ID]; !ok {
			return errInvalidCredentials
		}
		s.addSession(st, token, user.ID, now)
		return nil
	})
	if err != nil {
		return "", User{}, err
	}
	return token, user, nil
}

// Authenticate resolves a bearer token to its user.
func (s *Service) Authenticate(token string) (User, error) {
	digest := hashToken(token)
	var (
		user User
		ok   bool
	)
	now := s.now()
	s.db.View(func(st *state) {
		sess, found := st.Tokens[digest]
		if !found || !now.Before(sess.ExpiresAt) {
			return
		}
		if rec, found := st.Users[sess.UserID]; found {
			user, ok = rec.User, true
		}
	})
	if !ok {
		return User{}, errInvalidToken
	}
	return user, nil
}

// Lookup returns the user with the given ID.
func (s *Service) Lookup(id string) (User, bool) {
	var (
		user User
		ok   bool
	)
	s.db.View(func(st *state) {
		if rec, found := st.Users[id]; found {
			user, ok = rec.User, true
		}
	})
	return user, ok
}

// revoke deletes the session identified by its token digest.
func (s *Service) revoke(digest string) error {
	return s.db.Update(func(st *state) error {
		if _, ok := st.Tokens[digest]; !ok {
			return store.ErrNoChange
		}
		delete(st.Tokens, digest)
		return nil
	})
}

// addSession stores a new session and prunes expired ones while the state
// is locked for writing anyway.
func (s *Service) addSession(st *state, token, userID string, now time.Time) {
	for digest, sess := range st.Tokens {
		if !now.Before(sess.ExpiresAt) {
			delete(st.Tokens, digest)
		}
	}
	st.Tokens[hashToken(token)] = &session{UserID: userID, CreatedAt: now, ExpiresAt: now.Add(TokenTTL)}
}

func normalizeEmail(raw string) (string, bool) {
	email := strings.TrimSpace(raw)
	if email == "" || len(email) > maxEmailLen {
		return "", false
	}
	addr, err := mail.ParseAddress(email)
	if err != nil || addr.Address != email {
		return "", false
	}
	return strings.ToLower(email), true
}

func newToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
