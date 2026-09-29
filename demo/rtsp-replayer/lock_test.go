package replayer

import (
	"strings"
	"testing"
)

func TestEmbeddedLockAndPathsAreValid(t *testing.T) {
	lock, err := ParseLock(defaultLock)
	if err != nil {
		t.Fatalf("embedded clips.lock.json: %v", err)
	}
	if len(lock.Clips) != 3 {
		t.Fatalf("expected 3 locked clips, got %d", len(lock.Clips))
	}
	paths, err := ParsePaths(defaultPaths, lock)
	if err != nil {
		t.Fatalf("embedded paths.json: %v", err)
	}
	if len(paths.Paths) != 6 {
		t.Fatalf("expected 6 paths, got %d", len(paths.Paths))
	}
	// Every locked clip is served at least once.
	served := map[string]bool{}
	for _, p := range paths.Paths {
		served[p.Clip] = true
	}
	for _, c := range lock.Clips {
		if !served[c.Name] {
			t.Errorf("locked clip %q has no path", c.Name)
		}
	}
}

func TestParseLockRejects(t *testing.T) {
	valid := defaultLock
	cases := map[string]func(string) string{
		"bad version": func(s string) string { return strings.Replace(s, `"version": 1`, `"version": 2`, 1) },
		"empty bucket": func(s string) string {
			return strings.Replace(s, `"bucket": "serviceradar-demo-drone-clips"`, `"bucket": ""`, 1)
		},
		"short sha": func(s string) string {
			return strings.Replace(s, "21c49f2162047ca816946ddd6fcc59d64881a161daca4760f20dd46eb0a4598f", "21c49f21", 1)
		},
		"non-hex sha": func(s string) string {
			return strings.Replace(s, "21c49f2162047ca816946ddd6fcc59d64881a161daca4760f20dd46eb0a4598f", strings.Repeat("z", 64), 1)
		},
		"zero duration": func(s string) string {
			return strings.Replace(s, `"duration_seconds": 27.094`, `"duration_seconds": 0`, 1)
		},
		"missing license": func(s string) string { return strings.Replace(s, `"license": "CC BY 2.0"`, `"license": ""`, 1) },
		"bad key charset": func(s string) string {
			return strings.Replace(s, `"key": "highway-401.mp4"`, `"key": "highway 401.mp4"`, 1)
		},
		"duplicate name": func(s string) string {
			return strings.Replace(s, `"name": "quarry-excavators"`, `"name": "highway-401"`, 1)
		},
		"unknown field":   func(s string) string { return strings.Replace(s, `"bucket":`, `"bogus": 1, "bucket":`, 1) },
		"not json":        func(s string) string { return s[:len(s)-10] },
		"empty clips":     func(s string) string { return `{"version": 1, "bucket": "b", "clips": []}` },
		"zero resolution": func(s string) string { return strings.Replace(s, `"width": 1920`, `"width": 0`, 1) },
		"duplicate key": func(s string) string {
			return strings.Replace(s, `"key": "quarry-excavators.mp4"`, `"key": "highway-401.mp4"`, 1)
		},
		"empty clip name": func(s string) string { return strings.Replace(s, `"name": "highway-401"`, `"name": ""`, 1) },
		"missing source": func(s string) string {
			return strings.Replace(s, `"source_url": "https://commons.wikimedia.org/wiki/File:Aerial_view_(zoom_in)_of_overpasses_crossing_over_Highway_401_during_sunset_in_Toronto,_Canada..webm"`, `"source_url": ""`, 1)
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseLock([]byte(mutate(string(valid)))); err == nil {
				t.Fatalf("expected error, got nil")
			}
		})
	}
}

func TestParsePathsRejects(t *testing.T) {
	lock, err := ParseLock(defaultLock)
	if err != nil {
		t.Fatal(err)
	}
	valid := defaultPaths
	cases := map[string]func(string) string{
		"unknown clip": func(s string) string { return strings.Replace(s, `"clip": "highway-401"`, `"clip": "nope"`, 1) },
		"offset at end": func(s string) string {
			return strings.Replace(s, `"start_offset_seconds": 13.5`, `"start_offset_seconds": 27.094`, 1)
		},
		"offset past end": func(s string) string {
			return strings.Replace(s, `"start_offset_seconds": 13.5`, `"start_offset_seconds": 99`, 1)
		},
		"negative offset": func(s string) string {
			return strings.Replace(s, `"start_offset_seconds": 0`, `"start_offset_seconds": -1`, 1)
		},
		"duplicate path": func(s string) string {
			return strings.Replace(s, `"path": "drone-highway-b"`, `"path": "drone-highway"`, 1)
		},
		"empty path name": func(s string) string { return strings.Replace(s, `"path": "drone-highway"`, `"path": ""`, 1) },
		"bad path charset": func(s string) string {
			return strings.Replace(s, `"path": "drone-highway"`, `"path": "drone highway"`, 1)
		},
		"bad version": func(s string) string { return strings.Replace(s, `"version": 1`, `"version": 9`, 1) },
		"no paths":    func(s string) string { return `{"version": 1, "paths": []}` },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := ParsePaths([]byte(mutate(string(valid))), lock); err == nil {
				t.Fatalf("expected error, got nil")
			}
		})
	}
}

func TestClipByName(t *testing.T) {
	lock, err := ParseLock(defaultLock)
	if err != nil {
		t.Fatal(err)
	}
	c, ok := lock.ClipByName("tamarama-surf")
	if !ok {
		t.Fatalf("missing clip")
	}
	if c.Width != 1280 || c.Height != 720 {
		t.Fatalf("unexpected resolution %dx%d", c.Width, c.Height)
	}
	if _, ok := lock.ClipByName("nope"); ok {
		t.Fatalf("unexpected hit")
	}
}
