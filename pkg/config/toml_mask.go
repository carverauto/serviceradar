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
	inString := false
	escapeNext := false
	for i := 0; i < len(line); i++ {
		ch := line[i]
		if ch == '#' && !inString {
			break
		}
		if inString {
			if escapeNext {
				escapeNext = false
				continue
			}
			if ch == '\\' {
				escapeNext = true
				continue
			}
			if ch == '"' {
				inString = false
			}
			continue
		}
		if ch == '"' {
			inString = true
			continue
		}
		if ch == '=' {
			return strings.TrimSpace(line[:i])
		}
	}
	return ""
}
