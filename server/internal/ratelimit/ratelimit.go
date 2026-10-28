// Package ratelimit implements an in-memory token bucket per key.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// Limiter allows up to Burst requests at once per key, refilled at a steady
// rate of Burst tokens per Period. It is safe for concurrent use.
type Limiter struct {
	burst  float64
	rate   float64 // tokens per second
	now    func() time.Time
	mu     sync.Mutex
	bucket map[string]*bucket
	sweep  time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// New returns a limiter allowing burst requests per period for each key.
func New(burst int, period time.Duration) *Limiter {
	return &Limiter{
		burst:  float64(burst),
		rate:   float64(burst) / period.Seconds(),
		now:    time.Now,
		bucket: make(map[string]*bucket),
	}
}

// Allow consumes one token for key. When none is left it returns false and
// how long to wait before the next token is available.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	l.evictIdle(now)

	b, ok := l.bucket[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.bucket[key] = b
	}
	b.tokens = math.Min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	return false, wait
}

// evictIdle drops buckets that have refilled completely, at most once a
// minute, so the map does not grow without bound.
func (l *Limiter) evictIdle(now time.Time) {
	if now.Sub(l.sweep) < time.Minute {
		return
	}
	l.sweep = now
	full := time.Duration(l.burst / l.rate * float64(time.Second))
	for k, b := range l.bucket {
		if now.Sub(b.last) >= full {
			delete(l.bucket, k)
		}
	}
}
