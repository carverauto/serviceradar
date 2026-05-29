// Package normalize implements ecosystem-specific package name normalization.
package normalize

import (
	"strings"
	"unicode"
)

// NPM lowercases the name and preserves the scope. Scoped names retain
// the leading '@' and '/' separator.
func NPM(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

// PyPI applies PEP 503 normalization: lowercase, then collapse any run of
// '-', '_' or '.' into a single '-'.
func PyPI(name string) string {
	name = strings.ToLower(strings.TrimSpace(name))
	var b strings.Builder
	b.Grow(len(name))
	prevSep := false
	for _, r := range name {
		if r == '-' || r == '_' || r == '.' || unicode.IsSpace(r) {
			if !prevSep {
				b.WriteByte('-')
				prevSep = true
			}
			continue
		}
		b.WriteRune(r)
		prevSep = false
	}
	out := b.String()
	out = strings.Trim(out, "-")
	return out
}
