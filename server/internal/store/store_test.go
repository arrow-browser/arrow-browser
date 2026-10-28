package store

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

type counter struct {
	N     int               `json:"n"`
	Items map[string]string `json:"items"`
}

func TestFilePersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "state.json")
	f, err := Open[counter](path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Update(func(c *counter) error {
		c.N = 42
		c.Items = map[string]string{"a": "b"}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("file mode = %o, want 600", perm)
	}

	g, err := Open[counter](path)
	if err != nil {
		t.Fatal(err)
	}
	g.View(func(c *counter) {
		if c.N != 42 || c.Items["a"] != "b" {
			t.Fatalf("reopened value = %+v", c)
		}
	})
}

func TestUpdateRollsBackOnError(t *testing.T) {
	f, err := Open[counter](filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	_ = f.Update(func(c *counter) error { c.N = 1; return nil })

	boom := errors.New("boom")
	if err := f.Update(func(c *counter) error { c.N = 99; return boom }); !errors.Is(err, boom) {
		t.Fatalf("Update error = %v", err)
	}
	if err := f.Update(func(c *counter) error { c.N = 77; return ErrNoChange }); err != nil {
		t.Fatalf("ErrNoChange should be swallowed, got %v", err)
	}
	f.View(func(c *counter) {
		if c.N != 1 {
			t.Fatalf("value after failed updates = %d, want 1", c.N)
		}
	})
}

func TestUpdateRollsBackOnWriteFailure(t *testing.T) {
	dir := t.TempDir()
	f, err := Open[counter](filepath.Join(dir, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	if os.Geteuid() == 0 {
		t.Skip("root ignores directory permissions")
	}
	if err := f.Update(func(c *counter) error { c.N = 5; return nil }); err == nil {
		t.Fatal("expected write failure")
	}
	f.View(func(c *counter) {
		if c.N != 0 {
			t.Fatalf("value after failed write = %d, want 0", c.N)
		}
	})
}

func TestConcurrentUpdates(t *testing.T) {
	f, err := Open[counter](filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			_ = f.Update(func(c *counter) error { c.N++; return nil })
		})
	}
	wg.Wait()
	f.View(func(c *counter) {
		if c.N != 20 {
			t.Fatalf("N = %d, want 20", c.N)
		}
	})
}

func TestOpenRejectsCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open[counter](path); err == nil {
		t.Fatal("expected decode error")
	}
}

func TestWriteFileAtomicLeavesNoTempFiles(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "out.json")
	for i := range 3 {
		if err := WriteFileAtomic(path, []byte{byte('0' + i)}, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("dir has %d entries, want 1", len(entries))
	}
	data, _ := os.ReadFile(path)
	if string(data) != "2" {
		t.Fatalf("content = %q", data)
	}
}
