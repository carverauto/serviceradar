package db

import (
	"strings"
	"unicode"
)

func splitSQLStatements(content string) []string {
	var (
		statements []string
		current    strings.Builder
	)

	state := &sqlParseState{}

	for i := 0; i < len(content); i++ {
		ch := content[i]

		if state.inLineComment {
			if ch == '\n' {
				state.inLineComment = false
				current.WriteByte(ch)
			}
			continue
		}

		if state.inBlockComment {
			if ch == '*' && i+1 < len(content) && content[i+1] == '/' {
				state.inBlockComment = false
				i++
			}
			continue
		}

		if state.dollarTag != "" {
			if strings.HasPrefix(content[i:], state.dollarTag) {
				current.WriteString(state.dollarTag)
				i += len(state.dollarTag) - 1
				state.dollarTag = ""
				continue
			}

			current.WriteByte(ch)
			continue
		}

		if !state.inSingleQuote && !state.inDoubleQuote {
			if ch == '-' && i+1 < len(content) && content[i+1] == '-' {
				state.inLineComment = true
				i++
				continue
			}

			if ch == '/' && i+1 < len(content) && content[i+1] == '*' {
				state.inBlockComment = true
				i++
				continue
			}

			if tag, advance := parseDollarTag(content[i:]); tag != "" {
				state.dollarTag = tag
				current.WriteString(tag)
				i += advance - 1
				continue
			}
		}

		if !state.inDoubleQuote && ch == '\'' {
			state.inSingleQuote = !state.inSingleQuote
			current.WriteByte(ch)
			continue
		}

		if !state.inSingleQuote && ch == '"' {
			state.inDoubleQuote = !state.inDoubleQuote
			current.WriteByte(ch)
			continue
		}

		if ch == ';' && !state.inSingleQuote && !state.inDoubleQuote && state.dollarTag == "" {
			if stmt := strings.TrimSpace(current.String()); stmt != "" {
				statements = append(statements, stmt)
			}
			current.Reset()
			continue
		}

		current.WriteByte(ch)
	}

	if stmt := strings.TrimSpace(current.String()); stmt != "" {
		statements = append(statements, stmt)
	}

	return statements
}

type sqlParseState struct {
	inSingleQuote  bool
	inDoubleQuote  bool
	inLineComment  bool
	inBlockComment bool
	dollarTag      string
}

func parseDollarTag(content string) (string, int) {
	if content == "" || content[0] != '$' {
		return "", 0
	}

	for i := 1; i < len(content); i++ {
		if content[i] == '$' {
			return content[:i+1], i + 1
		}

		if !isDollarTagChar(content[i]) {
			return "", 0
		}
	}

	return "", 0
}

func isDollarTagChar(ch byte) bool {
	return ch == '_' || unicode.IsLetter(rune(ch)) || unicode.IsDigit(rune(ch))
}

func extractVersion(filename string) string {
	parts := strings.Split(filename, "_")
	if len(parts) == 0 {
		return filename
	}
	return parts[0]
}
