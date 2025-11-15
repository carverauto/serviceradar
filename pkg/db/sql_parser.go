package db

import "strings"

func splitSQLStatements(content string) []string {
	var statements []string
	var current strings.Builder
	lines := strings.Split(content, "\n")

	parser := &sqlStatementParser{}

	for _, line := range lines {
		if shouldSkipLine(line) {
			appendNewlineIfNeeded(&current)
			continue
		}

		appendLineToStatement(&current, line)
		parser.updateState(line)

		if parser.shouldSplitStatement(line) {
			if stmt := extractStatement(&current); stmt != "" {
				statements = append(statements, stmt)
			}

			current.Reset()
			parser.reset()
		}
	}

	if stmt := extractStatement(&current); stmt != "" {
		statements = append(statements, stmt)
	}

	return statements
}

type sqlStatementParser struct {
	inSettingsBlock  bool
	parenthesesDepth int
}

func shouldSkipLine(line string) bool {
	trimmed := strings.TrimSpace(line)
	return strings.HasPrefix(trimmed, "--") || trimmed == ""
}

func appendNewlineIfNeeded(stmt *strings.Builder) {
	if stmt.Len() > 0 {
		stmt.WriteString("\n")
	}
}

func appendLineToStatement(stmt *strings.Builder, line string) {
	appendNewlineIfNeeded(stmt)
	stmt.WriteString(line)
}

func (p *sqlStatementParser) updateState(line string) {
	trimmed := strings.TrimSpace(line)
	upper := strings.ToUpper(trimmed)

	if strings.Contains(upper, "SETTINGS") {
		p.inSettingsBlock = true
	}

	for _, ch := range line {
		switch ch {
		case '(':
			p.parenthesesDepth++
		case ')':
			p.parenthesesDepth--
		}
	}
}

func (p *sqlStatementParser) shouldSplitStatement(line string) bool {
	trimmed := strings.TrimSpace(line)
	if !strings.HasSuffix(trimmed, ";") {
		return false
	}

	if p.inSettingsBlock && p.parenthesesDepth == 0 {
		p.inSettingsBlock = false
	}

	return !p.inSettingsBlock
}

func (p *sqlStatementParser) reset() {
	p.parenthesesDepth = 0
}

func extractStatement(stmt *strings.Builder) string {
	if stmt.Len() == 0 {
		return ""
	}

	result := strings.TrimSpace(stmt.String())
	result = strings.TrimSuffix(result, ";")
	return result
}

func extractVersion(filename string) string {
	parts := strings.Split(filename, "_")
	if len(parts) == 0 {
		return filename
	}
	return parts[0]
}
