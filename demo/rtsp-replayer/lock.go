// Package replayer fetches licensed demo clips from object storage, verifies
// them against clips.lock.json, and serves each as a looping RTSP path
// through MediaMTX plus one ffmpeg publisher per path.
package replayer

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

var keyCharset = regexp.MustCompile(`^[A-Za-z0-9_./-]+$`)

// Clip is one locked demo clip: what to fetch, what it must hash to, and the
// license metadata the demo must attribute.
type Clip struct {
	Name            string  `json:"name"`
	Key             string  `json:"key"`
	SHA256          string  `json:"sha256"`
	DurationSeconds float64 `json:"duration_seconds"`
	Width           int     `json:"width"`
	Height          int     `json:"height"`
	FPS             string  `json:"fps"`
	SizeBytes       int64   `json:"size_bytes"`
	Codec           string  `json:"codec"`
	License         string  `json:"license"`
	LicenseURL      string  `json:"license_url"`
	Author          string  `json:"author"`
	SourceURL       string  `json:"source_url"`
}

// Lock is the parsed clips.lock.json.
type Lock struct {
	Version int    `json:"version"`
	Bucket  string `json:"bucket"`
	Notes   string `json:"notes,omitempty"`
	Clips   []Clip `json:"clips"`
}

// RTSPPath maps one served RTSP path to a locked clip and a publisher start
// delay in seconds. Staggered starts give paired paths different clip phases.
type RTSPPath struct {
	Path               string  `json:"path"`
	Clip               string  `json:"clip"`
	StartOffsetSeconds float64 `json:"start_offset_seconds"`
}

// Paths is the parsed paths.json.
type Paths struct {
	Version int        `json:"version"`
	Notes   string     `json:"notes,omitempty"`
	Paths   []RTSPPath `json:"paths"`
}

// ParseLock parses and validates a clips.lock.json document.
func ParseLock(data []byte) (*Lock, error) {
	var lock Lock
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&lock); err != nil {
		return nil, fmt.Errorf("parse lock: %w", err)
	}
	if lock.Version != 1 {
		return nil, fmt.Errorf("parse lock: unsupported version %d", lock.Version)
	}
	if lock.Bucket == "" {
		return nil, fmt.Errorf("parse lock: bucket is empty")
	}
	if len(lock.Clips) == 0 {
		return nil, fmt.Errorf("parse lock: no clips")
	}
	names := map[string]bool{}
	keys := map[string]bool{}
	for i := range lock.Clips {
		c := &lock.Clips[i]
		if c.Name == "" {
			return nil, fmt.Errorf("parse lock: clip %d has no name", i)
		}
		if names[c.Name] {
			return nil, fmt.Errorf("parse lock: duplicate clip name %q", c.Name)
		}
		names[c.Name] = true
		if c.Key == "" || !keyCharset.MatchString(c.Key) {
			return nil, fmt.Errorf("parse lock: clip %q has invalid key %q", c.Name, c.Key)
		}
		if keys[c.Key] {
			return nil, fmt.Errorf("parse lock: duplicate clip key %q", c.Key)
		}
		keys[c.Key] = true
		raw, err := hex.DecodeString(c.SHA256)
		if err != nil || len(raw) != 32 {
			return nil, fmt.Errorf("parse lock: clip %q has invalid sha256", c.Name)
		}
		if c.DurationSeconds <= 0 {
			return nil, fmt.Errorf("parse lock: clip %q has invalid duration %v", c.Name, c.DurationSeconds)
		}
		if c.Width <= 0 || c.Height <= 0 {
			return nil, fmt.Errorf("parse lock: clip %q has invalid resolution %dx%d", c.Name, c.Width, c.Height)
		}
		if c.License == "" || c.SourceURL == "" {
			return nil, fmt.Errorf("parse lock: clip %q is missing license metadata", c.Name)
		}
	}
	return &lock, nil
}

// ClipByName returns the locked clip with the given name.
func (l *Lock) ClipByName(name string) (Clip, bool) {
	for _, c := range l.Clips {
		if c.Name == name {
			return c, true
		}
	}
	return Clip{}, false
}

// ParsePaths parses and validates a paths.json document against the lock.
func ParsePaths(data []byte, lock *Lock) (*Paths, error) {
	var paths Paths
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&paths); err != nil {
		return nil, fmt.Errorf("parse paths: %w", err)
	}
	if paths.Version != 1 {
		return nil, fmt.Errorf("parse paths: unsupported version %d", paths.Version)
	}
	if len(paths.Paths) == 0 {
		return nil, fmt.Errorf("parse paths: no paths")
	}
	seen := map[string]bool{}
	for i := range paths.Paths {
		p := &paths.Paths[i]
		if p.Path == "" || !keyCharset.MatchString(p.Path) {
			return nil, fmt.Errorf("parse paths: path %d has invalid name %q", i, p.Path)
		}
		if seen[p.Path] {
			return nil, fmt.Errorf("parse paths: duplicate path %q", p.Path)
		}
		seen[p.Path] = true
		clip, ok := lock.ClipByName(p.Clip)
		if !ok {
			return nil, fmt.Errorf("parse paths: path %q names unknown clip %q", p.Path, p.Clip)
		}
		if p.StartOffsetSeconds < 0 || p.StartOffsetSeconds >= clip.DurationSeconds {
			return nil, fmt.Errorf(
				"parse paths: path %q offset %v outside clip %q duration %v",
				p.Path, p.StartOffsetSeconds, p.Clip, clip.DurationSeconds,
			)
		}
	}
	return &paths, nil
}
