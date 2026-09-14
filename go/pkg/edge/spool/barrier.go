/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package spool

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// ErrFailStopped is matched (errors.Is) by every error that stopped durable
// work: a failed barrier write, a failed destructive step, or any later request
// refused because one of those already happened. The underlying cause (for
// example syscall.ENOSPC or syscall.EIO) stays reachable through errors.Is too.
var ErrFailStopped = errors.New("spool: fail-stopped")

// FailStopError reports the storage operation whose failure stopped durable
// work. It is sticky: once returned, the spool or allocator that produced it
// refuses all further durable writes until the process reopens and re-measures.
//
// Every barrier failure is fail-stop, not only ENOSPC and EIO. After a failed
// write or fsync the bytes on disk, and whether they are durable, are unknown;
// retrying on top of that state is how a torn record ends up in the middle of a
// segment instead of at its tail.
type FailStopError struct {
	Op   string
	Path string
	Err  error
}

func (e *FailStopError) Error() string {
	if e.Path == "" {
		return fmt.Sprintf("spool: fail-stop: %s: %v", e.Op, e.Err)
	}
	return fmt.Sprintf("spool: fail-stop: %s %q: %v", e.Op, e.Path, e.Err)
}

func (e *FailStopError) Unwrap() error { return e.Err }

// Is makes every FailStopError match ErrFailStopped.
func (e *FailStopError) Is(target error) bool { return target == ErrFailStopped }

// durableFile is the part of *os.File a barrier write needs.
type durableFile interface {
	io.Writer
	Sync() error
	Close() error
}

// fileSystem is the storage seam for barrier writes. Production uses osFS; the
// tests inject ENOSPC and EIO at each barrier position through it.
type fileSystem interface {
	OpenFile(name string, flag int, perm os.FileMode) (durableFile, error)
	Rename(oldpath, newpath string) error
	Remove(name string) error
	SyncDir(dir string) error
}

type osFS struct{}

func (osFS) OpenFile(name string, flag int, perm os.FileMode) (durableFile, error) {
	return os.OpenFile(name, flag, perm)
}

func (osFS) Rename(oldpath, newpath string) error { return os.Rename(oldpath, newpath) }

func (osFS) Remove(name string) error { return os.Remove(name) }

func (osFS) SyncDir(dir string) error { return fsyncDir(dir) }

// writeBarrier durably replaces path with data: write a temporary file, fsync
// it, rename it over path, and fsync the directory so the rename survives a
// crash. Any failure returns a *FailStopError naming the operation.
//
// Before the rename, path is untouched, so the only thing removed on failure is
// the uncommitted temporary file (best effort, to give its bytes back). From
// the rename on nothing is removed: path may already name the new bytes, and
// deleting it would turn a failed barrier into a partial delete.
func writeBarrier(fsys fileSystem, path string, data []byte) error {
	tmp := path + ".tmp"
	f, err := fsys.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, filePerm)
	if err != nil {
		return &FailStopError{Op: "create", Path: tmp, Err: err}
	}

	if err := writeAndSync(f, tmp, data); err != nil {
		_ = f.Close()
		_ = fsys.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = fsys.Remove(tmp)
		return &FailStopError{Op: "close", Path: tmp, Err: err}
	}
	if err := fsys.Rename(tmp, path); err != nil {
		return &FailStopError{Op: "rename", Path: path, Err: err}
	}
	if err := fsys.SyncDir(filepath.Dir(path)); err != nil {
		return &FailStopError{Op: "fsync dir", Path: filepath.Dir(path), Err: err}
	}
	return nil
}

func writeAndSync(f durableFile, path string, data []byte) error {
	n, err := f.Write(data)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	if err != nil {
		return &FailStopError{Op: "write", Path: path, Err: err}
	}
	if err := f.Sync(); err != nil {
		return &FailStopError{Op: "fsync", Path: path, Err: err}
	}
	return nil
}
