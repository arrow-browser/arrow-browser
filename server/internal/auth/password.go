package auth

import (
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	// DefaultIterations follows the OWASP recommendation for PBKDF2-HMAC-SHA256.
	DefaultIterations = 600_000
	saltLen           = 16
	keyLen            = 32
	hashScheme        = "pbkdf2_sha256"
)

var b64 = base64.RawStdEncoding

// hashPassword returns "pbkdf2_sha256$<iterations>$<salt>$<key>". The
// iteration count is stored so it can be raised later without breaking
// existing hashes.
func hashPassword(password string, iterations int) (string, error) {
	salt := make([]byte, saltLen)
	_, _ = rand.Read(salt) // never fails; see crypto/rand.Read
	key, err := pbkdf2.Key(sha256.New, password, salt, iterations, keyLen)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s$%d$%s$%s", hashScheme, iterations, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

// verifyPassword reports whether password matches encoded, comparing the
// derived keys in constant time.
func verifyPassword(password, encoded string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 4 || parts[0] != hashScheme {
		return false, errors.New("auth: unknown password hash format")
	}
	iterations, err := strconv.Atoi(parts[1])
	if err != nil || iterations <= 0 {
		return false, errors.New("auth: invalid iteration count")
	}
	salt, err := b64.DecodeString(parts[2])
	if err != nil {
		return false, err
	}
	want, err := b64.DecodeString(parts[3])
	if err != nil {
		return false, err
	}
	got, err := pbkdf2.Key(sha256.New, password, salt, iterations, len(want))
	if err != nil {
		return false, err
	}
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}
