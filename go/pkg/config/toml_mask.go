package config

import (
	"bytes"
	"strings"
)

// TOMLPath identifies a specific key inside an optional table (e.g. table="outputs.prometheus", key="token").
// Use Table="*" to match keys in any table or Key="*" to drop an entire table.
type TOMLPath struct {
	Table string
	Key   string
}

// SanitizeTOML drops lines containing sensitive keys from a TOML document without needing a full parser.
// It handles basic table headers ([table]) and key/value pairs (key = value). Multiline strings or inline
// tables are preserved unless the first line contains a denied key.
func SanitizeTOML(data []byte, deny []TOMLPath) []byte {
	if len(data) == 0 || len(deny) == 0 {
		return data
	}

	denyMap := buildTOMLDenyMap(deny)

	var (
		buf          bytes.Buffer
		currentTable = ""
	)

	lines := bytes.Split(data, []byte("\n"))
	for _, rawLine := range lines {
		line := strings.TrimSpace(string(rawLine))
		if line == "" || strings.HasPrefix(line, "#") {
			buf.Write(rawLine)
			buf.WriteByte('\n')
			continue
		}

		if isTableHeader(line) {
			currentTable = strings.Trim(line, "[]")
			buf.Write(rawLine)
			buf.WriteByte('\n')
			continue
		}

		key := extractKey(line)
		if key == "" {
			buf.Write(rawLine)
			buf.WriteByte('\n')
			continue
		}

		if shouldDropTOMLKey(currentTable, key, denyMap) {
			continue
		}

		buf.Write(rawLine)
		buf.WriteByte('\n')
	}

	return bytes.TrimRight(buf.Bytes(), "\n")
}

func buildTOMLDenyMap(deny []TOMLPath) map[string]map[string]struct{} {
	result := make(map[string]map[string]struct{}, len(deny))
	for _, path := range deny {
		table := path.Table
		if table == "" {
			table = ""
		}
		key := path.Key
		if key == "" {
			key = "*"
		}
		if _, ok := result[table]; !ok {
			result[table] = make(map[string]struct{})
		}
		result[table][key] = struct{}{}
	}
	return result
}

func shouldDropTOMLKey(table, key string, deny map[string]map[string]struct{}) bool {
	if keys, ok := deny[table]; ok {
		if _, match := keys["*"]; match {
			return true
		}
		if _, match := keys[key]; match {
			return true
		}
	}

	if keys, ok := deny["*"]; ok {
		if _, match := keys["*"]; match {
			return true
		}
		if _, match := keys[key]; match {
			return true
		}
	}

	return false
}

func isTableHeader(line string) bool {
	return strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]")
}

func extractKey(line string) string {
	scanner := tomlKeyScanner{}
	for i := 0; i < len(line); i++ {
		ch := line[i]

		if scanner.shouldStopAtComment(ch) {
			break
		}

		if scanner.handleMultiline(line, &i) {
			continue
		}

		if scanner.handleSingleString(ch) {
			continue
		}

		if scanner.handleBasicString(ch) {
			continue
		}

		if scanner.handleBrackets(ch) {
			continue
		}

		if ch == '=' && scanner.bracketDepth == 0 {
			return strings.TrimSpace(line[:i])
		}
	}
	return ""
}

type tomlKeyScanner struct {
	inBasicString  bool
	inSingleString bool
	inMultiline    bool
	escapeNext     bool
	bracketDepth   int
}

func (s *tomlKeyScanner) inAnyString() bool {
	return s.inBasicString || s.inSingleString || s.inMultiline
}

func (s *tomlKeyScanner) shouldStopAtComment(ch byte) bool {
	return ch == '#' && !s.inAnyString()
}

func (s *tomlKeyScanner) handleMultiline(line string, idx *int) bool {
	if s.inSingleString {
		return false
	}
	if !s.inMultiline {
		if s.inBasicString {
			return false
		}
		if hasTripleQuote(line, *idx) {
			s.inMultiline = true
			*idx += 2
			return true
		}
		return false
	}
	if hasTripleQuote(line, *idx) {
		s.inMultiline = false
		*idx += 2
	}
	return true
}

func (s *tomlKeyScanner) handleSingleString(ch byte) bool {
	if s.inBasicString || s.inMultiline {
		return false
	}
	if s.inSingleString {
		if ch == '\'' {
			s.inSingleString = false
		}
		return true
	}
	if ch == '\'' {
		s.inSingleString = true
		return true
	}
	return false
}

func (s *tomlKeyScanner) handleBasicString(ch byte) bool {
	if s.inSingleString || s.inMultiline {
		return false
	}
	if s.inBasicString {
		if s.escapeNext {
			s.escapeNext = false
			return true
		}
		if ch == '\\' {
			s.escapeNext = true
			return true
		}
		if ch == '"' {
			s.inBasicString = false
		}
		return true
	}
	if ch == '"' {
		s.inBasicString = true
		return true
	}
	return false
}

func (s *tomlKeyScanner) handleBrackets(ch byte) bool {
	if s.inAnyString() {
		return false
	}
	switch ch {
	case '[', '{', '(':
		s.bracketDepth++
		return true
	case ']', '}', ')':
		if s.bracketDepth > 0 {
			s.bracketDepth--
		}
		return true
	default:
		return false
	}
}

func hasTripleQuote(line string, idx int) bool {
	return idx+2 < len(line) && line[idx] == '"' && line[idx+1] == '"' && line[idx+2] == '"'
}
