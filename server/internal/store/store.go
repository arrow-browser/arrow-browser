// Package store persists small JSON documents on disk. Every write replaces
// the whole file atomically (temp file + fsync + rename), so a crash never
// leaves a half-written file behind.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
)

// ErrNoChange may be returned from an Update callback to skip the write.
var ErrNoChange = errors.New("store: no change")

// File keeps a value of type T in memory and mirrors it to a JSON file.
type File[T any] struct {
	mu    sync.RWMutex
	path  string
	value T
	saved []byte // last bytes successfully written; used to roll back
}

// Open loads path into memory, or starts from the zero value if the file
// does not exist yet. The parent directory is created if needed.
func Open[T any](path string) (*File[T], error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	f := &File[T]{path: path}
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return f, nil
	case err != nil:
		return nil, err
	}
	if err := json.Unmarshal(data, &f.value); err != nil {
		return nil, fmt.Errorf("store: decode %s: %w", path, err)
	}
	f.saved = data
	return f, nil
}

// View runs fn with read access. fn must not retain or mutate the value.
func (f *File[T]) View(fn func(v *T)) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	fn(&f.value)
}

// Update runs fn with exclusive access and persists the result. If fn or the
// write fails, the in-memory value is rolled back to the last saved state.
func (f *File[T]) Update(fn func(v *T) error) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := fn(&f.value); err != nil {
		f.rollback()
		if errors.Is(err, ErrNoChange) {
			return nil
		}
		return err
	}
	data, err := json.Marshal(&f.value)
	if err != nil {
		f.rollback()
		return err
	}
	if err := WriteFileAtomic(f.path, data, 0o600); err != nil {
		f.rollback()
		return err
	}
	f.saved = data
	return nil
}

func (f *File[T]) rollback() {
	var v T
	if f.saved != nil {
		// saved was produced by json.Marshal of a T, so it always decodes.
		_ = json.Unmarshal(f.saved, &v)
	}
	f.value = v
}

// WriteFileAtomic writes data to path via a temporary file in the same
// directory followed by a rename.
func WriteFileAtomic(path string, data []byte, perm fs.FileMode) (err error) {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = tmp.Close()
			_ = os.Remove(tmp.Name())
		}
	}()
	if _, err = tmp.Write(data); err != nil {
		return err
	}
	if err = tmp.Chmod(perm); err != nil {
		return err
	}
	if err = tmp.Sync(); err != nil {
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	if err = os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	// Persist the rename itself; best effort since not every OS supports it.
	if d, derr := os.Open(dir); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
