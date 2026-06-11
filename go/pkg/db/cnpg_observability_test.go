package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestSanitizeObservabilityTable(t *testing.T) {
	t.Parallel()

	testCases := []struct {
		name       string
		input      string
		defaultVal string
		wantSQL    string
		wantCanon  string
	}{
		{
			name:       "default-when-empty",
			input:      "",
			defaultVal: "logs",
			wantSQL:    `"logs"`,
			wantCanon:  "logs",
		},
		{
			name:       "schema-table",
			input:      "observability.logs",
			defaultVal: "logs",
			wantSQL:    `"observability"."logs"`,
			wantCanon:  "observability.logs",
		},
		{
			name:       "trimmed-parts",
			input:      "  custom . metrics  ",
			defaultVal: "otel_metrics",
			wantSQL:    `"custom"."metrics"`,
			wantCanon:  "custom.metrics",
		},
		{
			name:       "leading-dot",
			input:      ".traces",
			defaultVal: "otel_traces",
			wantSQL:    `"traces"`,
			wantCanon:  "traces",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			sql, canon := sanitizeObservabilityTable(tc.input, tc.defaultVal)
			require.Equal(t, tc.wantSQL, sql)
			require.Equal(t, tc.wantCanon, canon)
		})
	}
}

// TestBuildOTELTracesInsertQueryColumnContract pins the otel_traces column
// contract: the correlation columns are present, trace_state and
// scope_attributes store NULL (via NULLIF) when the row struct carries "",
// and the placeholder count matches the queued argument count.
func TestBuildOTELTracesInsertQueryColumnContract(t *testing.T) {
	t.Parallel()

	query := buildOTELTracesInsertQuery(`"otel_traces"`)

	for _, column := range []string{
		"trace_state",
		"scope_attributes",
		"dropped_attributes_count",
		"dropped_events_count",
		"dropped_links_count",
		"service_namespace",
		"deployment_environment",
	} {
		require.Contains(t, query, column)
	}

	require.Contains(t, query, "NULLIF($20,'')", "trace_state must store NULL for empty strings")
	require.Contains(t, query, "NULLIF($21,'')", "scope_attributes must store NULL for empty strings")
	require.Contains(t, query, "$26", "expected 26 bind parameters")
	require.NotContains(t, query, "$27")
}
