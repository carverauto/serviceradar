package replayer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
)

// EnsureClips makes the local clip directory match the lock: every locked
// clip present with a verified digest. Any bucket object
// outside the lock refuses startup. A downloaded clip whose digest mismatches
// is deleted and refused; nothing unverified is ever served.
func EnsureClips(ctx context.Context, log *log.Logger, s3 *S3Client, lock *Lock, dir string) error {
	keys, err := s3.ListKeys(ctx)
	if err != nil {
		return err
	}
	locked := map[string]bool{}
	for _, c := range lock.Clips {
		locked[c.Key] = true
	}
	var unlisted []string
	for _, key := range keys {
		if !locked[key] {
			unlisted = append(unlisted, key)
		}
	}
	if len(unlisted) > 0 {
		sort.Strings(unlisted)
		return fmt.Errorf("refusing startup: %d bucket object(s) outside clips.lock.json: %s", len(unlisted), joinN(unlisted, 8))
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create clips dir: %w", err)
	}
	for _, clip := range lock.Clips {
		if err := ctx.Err(); err != nil {
			return err
		}
		dest := filepath.Join(dir, filepath.Base(clip.Key))
		if matches, err := verifyFile(dest, clip.SHA256); err != nil {
			return err
		} else if matches {
			log.Printf("clip %s already verified, keeping", clip.Name)
			continue
		}
		log.Printf("clip %s fetching s3://%s/%s", clip.Name, s3.Bucket, clip.Key)
		if err := downloadVerified(ctx, s3, clip, dest); err != nil {
			return err
		}
		log.Printf("clip %s verified (%d bytes)", clip.Name, clip.SizeBytes)
	}
	return nil
}

// verifyFile reports whether path exists with the expected hex digest. A
// missing file is not an error; anything unreadable is.
func verifyFile(path, wantHex string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("open %s: %w", path, err)
	}
	defer func() { _ = f.Close() }()
	sum, err := hashReader(f)
	if err != nil {
		return false, fmt.Errorf("hash %s: %w", path, err)
	}
	return sum == wantHex, nil
}

func downloadVerified(ctx context.Context, s3 *S3Client, clip Clip, dest string) error {
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".clip-*")
	if err != nil {
		return fmt.Errorf("clip %s: temp file: %w", clip.Name, err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	hash := sha256.New()
	if err := s3.GetObject(ctx, clip.Key, io.MultiWriter(tmp, hash)); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("clip %s: %w", clip.Name, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("clip %s: close temp: %w", clip.Name, err)
	}
	if got := hex.EncodeToString(hash.Sum(nil)); got != clip.SHA256 {
		return fmt.Errorf("clip %s: refusing digest mismatch (want %.16s, got %.16s)", clip.Name, clip.SHA256, got)
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return fmt.Errorf("clip %s: chmod: %w", clip.Name, err)
	}
	if err := os.Rename(tmpName, dest); err != nil {
		return fmt.Errorf("clip %s: install: %w", clip.Name, err)
	}
	return nil
}

func hashReader(r io.Reader) (string, error) {
	hash := sha256.New()
	if _, err := io.Copy(hash, r); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func joinN(items []string, n int) string {
	if len(items) > n {
		return fmt.Sprintf("%s, ... (%d more)", joinN(items[:n], n), len(items)-n)
	}
	out := ""
	for i, item := range items {
		if i > 0 {
			out += ", "
		}
		out += item
	}
	return out
}
