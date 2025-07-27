package srql_test

import (
	"testing"

	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestParseTimestamp(t *testing.T) {
	// p := srql.NewParser() // If srql.NewParser wraps parser.NewParser
	p := parser.NewParser() // Or use the direct parser
	query := "show devices where timestamp = '2023-12-25 14:30:00'"
	parsed, err := p.Parse(query)
	require.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity) // Ensure this EntityType is correct
	require.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "timestamp", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "2023-12-25 14:30:00", parsed.Conditions[0].Value)
}

func TestParseIPAddress(t *testing.T) {
	p := parser.NewParser()
	query := "show devices where ip = '192.168.1.1'"
	parsed, err := p.Parse(query)
	require.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity)
	require.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "ip", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "192.168.1.1", parsed.Conditions[0].Value)
}

func TestParseMACAddress(t *testing.T) {
	p := parser.NewParser()
	query := "show devices where mac = '00:1A:2B:3C:4D:5E'"
	parsed, err := p.Parse(query)
	require.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity)
	require.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "mac", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "00:1A:2B:3C:4D:5E", parsed.Conditions[0].Value)
}

func TestSRQLParsingAndTranslation(t *testing.T) { // Renamed for clarity
	p := parser.NewParser()

	// Define translators once
	protonTranslator := parser.NewTranslator(parser.Proton)
	clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)
	arangoTranslator := parser.NewTranslator(parser.ArangoDB)

	testCases := []struct {
		name          string
		query         string
		expectedError bool
		validate      func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:  "Simple show query for devices",
			query: "show devices",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Devices, query.Entity)

				sqlCH, _ := clickhouseTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM devices", sqlCH)
				aql, _ := arangoTranslator.Translate(query)
				assert.Equal(t, "FOR doc IN devices\n  RETURN doc", aql)
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(unified_devices) "+
					"WHERE coalesce(metadata['_deleted'], '') != 'true'", sqlP)
			},
		},
		{
			name:  "Simple show query for services",
			query: "show services",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Services, query.Entity)

				sqlCH, _ := clickhouseTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM services", sqlCH)
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(services)", sqlP)
			},
		},
		{
			name:  "Show query for devices with IP condition",
			query: "show devices where ip = '192.168.1.1'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Devices, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "ip", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, "192.168.1.1", query.Conditions[0].Value)

				sqlCH, _ := clickhouseTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM devices WHERE ip = '192.168.1.1'", sqlCH)
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(unified_devices) WHERE (ip = '192.168.1.1') "+
					"AND coalesce(metadata['_deleted'], '') != 'true'", sqlP)
			},
		},
		{
			name:          "Invalid query - syntax error",
			query:         "shoe devices",
			expectedError: true,
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.Error(t, err)
				assert.Contains(t, err.Error(), "syntax error") // Or the specific error from your listener
				assert.Nil(t, query)
			},
		},

		{
			name:  "Show events simple query",
			query: "show events",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Events, query.Entity)
				assert.Empty(t, query.Conditions)

				sqlP, errP := protonTranslator.Translate(query)
				require.NoError(t, errP)
				assert.Equal(t, "SELECT * FROM table(events)", sqlP)
			},
		},
		{
			name:  "SHOW query with DISTINCT function",
			query: "SHOW DISTINCT(service_name) FROM logs WHERE service_name IS NOT NULL",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Logs, query.Entity)
				assert.Equal(t, "distinct", query.Function)
				assert.Equal(t, []string{"service_name"}, query.FunctionArgs)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "service_name", query.Conditions[0].Field)
				assert.Equal(t, models.Is, query.Conditions[0].Operator)

				sqlP, errP := protonTranslator.Translate(query)
				require.NoError(t, errP)
				expected := "SELECT DISTINCT service_name FROM table(logs) WHERE service_name IS NOT NULL"
				assert.Equal(t, expected, sqlP)

				sqlCH, errCH := clickhouseTranslator.Translate(query)
				require.NoError(t, errCH)
				expectedCH := "SELECT DISTINCT service_name FROM logs WHERE service_name IS NOT NULL"
				assert.Equal(t, expectedCH, sqlCH)
			},
		},
		{
			name:  "SHOW DISTINCT with ORDER BY",
			query: "SHOW DISTINCT(ip) FROM devices WHERE ip IS NOT NULL ORDER BY ip ASC",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Devices, query.Entity)
				assert.Equal(t, "distinct", query.Function)
				assert.Equal(t, []string{"ip"}, query.FunctionArgs)
				require.Len(t, query.OrderBy, 1)
				assert.Equal(t, "ip", query.OrderBy[0].Field)
				assert.Equal(t, models.Ascending, query.OrderBy[0].Direction)

				sqlP, errP := protonTranslator.Translate(query)
				require.NoError(t, errP)
				expected := "SELECT DISTINCT ip FROM table(unified_devices) WHERE (ip IS NOT NULL) " +
					"AND coalesce(metadata['_deleted'], '') != 'true' ORDER BY ip ASC"
				assert.Equal(t, expected, sqlP)
			},
		},
		{
			name:  "SHOW DISTINCT with LIMIT",
			query: "SHOW DISTINCT(host) FROM events WHERE host IS NOT NULL LIMIT 10",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				assert.Equal(t, "distinct", query.Function)
				assert.Equal(t, []string{"host"}, query.FunctionArgs)
				assert.True(t, query.HasLimit)
				assert.Equal(t, 10, query.Limit)

				sqlP, errP := protonTranslator.Translate(query)
				require.NoError(t, errP)
				expected := "SELECT DISTINCT host FROM table(events) WHERE host IS NOT NULL LIMIT 10"
				assert.Equal(t, expected, sqlP)
			},
		},
		// Add more tests:
		// - Multiple conditions with date(timestamp) and other fields
		// - date(timestamp) with LATEST keyword (clarify expected behavior for LATEST with date filters)
		// - Ensure entity `device_updates` is correctly recognized (may need grammar update for entity rule)
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			parsedQuery, err := p.Parse(tc.query) // Use 'parsedQuery' to avoid conflict
			if tc.expectedError {
				require.Error(t, err)

				if err != nil { // Check if an error actually occurred
					assert.Contains(t, err.Error(), "syntax error", "Error message should indicate syntax error")
				}
			} else {
				require.NoError(t, err, "Query parsing failed unexpectedly")
			}

			tc.validate(t, parsedQuery, err)
		})
	}
}

func TestSRQLEdgeCases(t *testing.T) {
	p := parser.NewParser()
	translator := parser.NewTranslator(parser.ClickHouse) // Using ClickHouse for this example

	// Test case-insensitivity for keywords and fields (translator should lowercase fields)
	upperQuery := "SHOW DEVICES WHERE IP = '192.168.1.1' ORDER BY IP DESC LIMIT 10"
	parsedUpper, errUpper := p.Parse(upperQuery)
	require.NoError(t, errUpper)

	// Check parsed model for field casing (should be as-is from parser or visitor convention)
	assert.Equal(t, "IP", parsedUpper.Conditions[0].Field) // Visitor might keep ID casing
	assert.Equal(t, "IP", parsedUpper.OrderBy[0].Field)

	// Translator should handle field casing
	sqlUpper, errSQLUpper := translator.Translate(parsedUpper)
	require.NoError(t, errSQLUpper)
	assert.Equal(t, "SELECT * FROM devices WHERE ip = '192.168.1.1' ORDER BY ip DESC LIMIT 10", sqlUpper)

	mixedQuery := "Show Devices Where Ip = '192.168.1.1' Order By Ip Asc"
	parsedMixed, errMixed := p.Parse(mixedQuery)
	require.NoError(t, errMixed)

	// Check parsed model field casing
	assert.Equal(t, "Ip", parsedMixed.Conditions[0].Field)
	assert.Equal(t, "Ip", parsedMixed.OrderBy[0].Field)

	sqlMixed, errSQLMixed := translator.Translate(parsedMixed)
	require.NoError(t, errSQLMixed)

	// Assuming translator normalizes 'Ip' to 'ip' and 'Asc' to 'ASC'
	assert.Equal(t, "SELECT * FROM devices WHERE ip = '192.168.1.1' ORDER BY ip ASC", sqlMixed)
}
