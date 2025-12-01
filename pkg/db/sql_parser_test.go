package db

import (
	"strings"
	"testing"
)

func TestSplitSQLStatementsHandlesDollarQuotedBlocks(t *testing.T) {
	content := `
-- Enable extension
CREATE EXTENSION IF NOT EXISTS age;

DO $$
BEGIN
    PERFORM set_config('graph_path', 'serviceradar', false);
    PERFORM do_something();
END $$;

SELECT 1;
`

	statements := splitSQLStatements(content)

	if len(statements) != 3 {
		t.Fatalf("expected 3 statements, got %d: %#v", len(statements), statements)
	}

	if statements[1] == "" || statements[1][:2] != "DO" {
		t.Fatalf("expected DO block as second statement, got %q", statements[1])
	}

	if statements[2] != "SELECT 1" {
		t.Fatalf("unexpected tail statement: %q", statements[2])
	}
}

func TestSplitSQLStatementsIgnoresSemicolonsInQuotes(t *testing.T) {
	content := `
INSERT INTO logs(message) VALUES('hello;world');
DO $tag$
BEGIN
    PERFORM do_something('value;with;semicolons');
END $tag$;
`

	statements := splitSQLStatements(content)

	if len(statements) != 2 {
		t.Fatalf("expected 2 statements, got %d: %#v", len(statements), statements)
	}

	if !strings.HasPrefix(statements[0], "INSERT") {
		t.Fatalf("unexpected first statement: %q", statements[0])
	}

	if !strings.HasPrefix(statements[1], "DO") || !strings.HasSuffix(statements[1], "$tag$") {
		t.Fatalf("unexpected DO statement: %q", statements[1])
	}
}
