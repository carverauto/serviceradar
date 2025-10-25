package hydrate

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
)

//go:embed bundle.json
var embeddedBundle []byte

var (
	defaultBundle     *Bundle
	defaultBundleErr  error
	defaultBundleOnce sync.Once
)

// Bundle describes the collection of packaged configuration defaults.
type Bundle struct {
	GeneratedAt time.Time      `json:"generated_at"`
	Components  []Component    `json:"components"`
	byName      map[string]int // populated lazily for lookups
}

// Component groups configuration files for a specific ServiceRadar component.
type Component struct {
	Name  string       `json:"name"`
	Files []ConfigFile `json:"files"`
}

// ConfigFile contains a single configuration document destined for the KV store.
type ConfigFile struct {
	KVKey    string          `json:"kv_key"`
	Source   string          `json:"source"`
	Dest     string          `json:"dest"`
	Optional bool            `json:"optional,omitempty"`
	Data     json.RawMessage `json:"data"`
}

// Bytes returns the raw JSON document for the configuration file.
func (f ConfigFile) Bytes() []byte {
	return []byte(f.Data)
}

// Default returns the embedded bundle generated at build time.
func Default() (*Bundle, error) {
	defaultBundleOnce.Do(func() {
		defaultBundle, defaultBundleErr = Load(embeddedBundle)
	})

	return defaultBundle, defaultBundleErr
}

// Load parses a bundle JSON payload.
func Load(data []byte) (*Bundle, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("bundle payload is empty")
	}

	var b Bundle
	if err := json.Unmarshal(data, &b); err != nil {
		return nil, fmt.Errorf("failed to parse bundle: %w", err)
	}

	if len(b.Components) == 0 {
		return nil, fmt.Errorf("bundle contains no components")
	}

	b.index()

	return &b, nil
}

// ComponentNames returns the list of component identifiers included in the bundle.
func (b *Bundle) ComponentNames() []string {
	names := make([]string, len(b.Components))
	for i, comp := range b.Components {
		names[i] = comp.Name
	}

	return names
}

// FindComponents returns the set of components matching the provided selectors.
// Selectors are matched case-insensitively. The special selector "all" yields
// every component.
func (b *Bundle) FindComponents(selectors []string) ([]Component, error) {
	if len(selectors) == 0 {
		return b.Components, nil
	}

	normalized := normalizeSelectors(selectors)
	if normalized["all"] {
		return b.Components, nil
	}

	var result []Component
	for name := range normalized {
		idx, ok := b.byName[name]
		if !ok {
			return nil, fmt.Errorf("unknown component %q", name)
		}

		result = append(result, b.Components[idx])
	}

	return result, nil
}

func (b *Bundle) index() {
	b.byName = make(map[string]int, len(b.Components))
	for i, comp := range b.Components {
		b.byName[strings.ToLower(comp.Name)] = i
	}
}

func normalizeSelectors(selectors []string) map[string]bool {
	result := make(map[string]bool, len(selectors))

	for _, sel := range selectors {
		if sel == "" {
			continue
		}

		for _, part := range strings.Split(sel, ",") {
			name := strings.ToLower(strings.TrimSpace(part))
			if name != "" {
				result[name] = true
			}
		}
	}

	return result
}
