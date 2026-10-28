package ratelimit

import (
	"testing"
	"time"
)

func TestLimiter(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := New(3, time.Minute) // one token every 20s
	l.now = func() time.Time { return now }

	for i := range 3 {
		if ok, _ := l.Allow("alice"); !ok {
			t.Fatalf("request %d rejected within burst", i)
		}
	}
	ok, wait := l.Allow("alice")
	if ok {
		t.Fatal("4th request allowed")
	}
	if wait <= 0 || wait > 20*time.Second {
		t.Fatalf("retry after = %v, want (0, 20s]", wait)
	}
	if ok, _ := l.Allow("bob"); !ok {
		t.Fatal("keys must be independent")
	}

	now = now.Add(20 * time.Second)
	if ok, _ := l.Allow("alice"); !ok {
		t.Fatal("token not refilled after 20s")
	}
	if ok, _ := l.Allow("alice"); ok {
		t.Fatal("only one token should have been refilled")
	}
}

func TestLimiterEvictsIdleBuckets(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	l := New(2, time.Minute)
	l.now = func() time.Time { return now }
	l.Allow("a")
	l.Allow("b")
	now = now.Add(2 * time.Minute)
	l.Allow("c")
	if len(l.bucket) != 1 {
		t.Fatalf("buckets = %d, want 1 after eviction", len(l.bucket))
	}
}
