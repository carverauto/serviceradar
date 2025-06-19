package srql_test

import (
	"fmt"
	"testing"
	"time" // Import time package for ArangoDB date string generation

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
				assert.Equal(t, "SELECT * FROM table(unified_devices)", sqlP)
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
				assert.Equal(t, "SELECT * FROM table(unified_devices) WHERE ip = '192.168.1.1'", sqlP)
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
		// --- New Test Cases for sweep_results and date functions ---
		{
			name:  "Show sweep_results for TODAY and available",
			query: "show sweep_results where date(timestamp) = TODAY and available = true",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.SweepResults, query.Entity) // Make sure this entity type is correct
				require.Len(t, query.Conditions, 2)

				// Condition 1: date(timestamp) = TODAY
				cond1 := query.Conditions[0]
				assert.Equal(t, "date(timestamp)", cond1.Field) // As parsed by your visitor
				assert.Equal(t, models.Equals, cond1.Operator)
				assert.Equal(t, "TODAY", cond1.Value)

				// Condition 2: available = true
				cond2 := query.Conditions[1]
				assert.Equal(t, "available", cond2.Field)
				assert.Equal(t, models.Equals, cond2.Operator)
				assert.Equal(t, true, cond2.Value) // Assuming boolean 'true' is parsed to Go bool true
				assert.Equal(t, models.And, cond2.LogicalOp)

				// Test Proton translation
				sqlP, errP := protonTranslator.Translate(query)
				require.NoError(t, errP)
				assert.Equal(t, "SELECT * FROM table(sweep_results) "+
					"WHERE to_date(timestamp) = today() AND available = true", sqlP)

				// Test ClickHouse translation
				sqlCH, errCH := clickhouseTranslator.Translate(query)
				require.NoError(t, errCH)
				assert.Equal(t, "SELECT * FROM sweep_results WHERE "+
					"toDate(timestamp) = today() AND available = true", sqlCH) // Assuming toDate for CH

				// Test ArangoDB translation
				aql, errA := arangoTranslator.Translate(query)
				require.NoError(t, errA)
				todayDateStr := time.Now().Format("2006-01-02")
				// Assuming SUBSTRING for Arango if timestamp is string, or DATE_TRUNC if native date
				expectedAQL := fmt.Sprintf("FOR doc IN sweep_results\n  "+
					"FILTER SUBSTRING(doc.timestamp, 0, 10) == '%s' AND doc.available == true\n  "+
					"RETURN doc", todayDateStr)
				assert.Equal(t, expectedAQL, aql)
			},
		},
		{
			name:  "Show sweep_results for YESTERDAY and not available",
			query: "show sweep_results where date(timestamp) = YESTERDAY and available = false",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.SweepResults, query.Entity)
				require.Len(t, query.Conditions, 2)

				assert.Equal(t, "date(timestamp)", query.Conditions[0].Field)
				assert.Equal(t, "YESTERDAY", query.Conditions[0].Value)
				assert.False(t, query.Conditions[1].Value.(bool)) // Ensure boolean parsing

				// Proton
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(sweep_results) "+
					"WHERE to_date(timestamp) = yesterday() AND available = false", sqlP)

				// ClickHouse
				sqlCH, _ := clickhouseTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM sweep_results WHERE toDate(timestamp) = yesterday() "+
					"AND available = false", sqlCH)

				// ArangoDB
				aql, _ := arangoTranslator.Translate(query)
				yesterdayDateStr := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
				expectedAQL := fmt.Sprintf(
					"FOR doc IN sweep_results\n  FILTER SUBSTRING(doc.timestamp, 0, 10) == '%s' "+
						"AND doc.available == false\n  RETURN doc", yesterdayDateStr)
				assert.Equal(t, expectedAQL, aql)
			},
		},
		{
			name:  "Show sweep_results for a specific date string",
			query: "show sweep_results where date(timestamp) = '2023-10-20'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.SweepResults, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "date(timestamp)", query.Conditions[0].Field)
				assert.Equal(t, "2023-10-20", query.Conditions[0].Value)

				// Proton
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(sweep_results) WHERE to_date(timestamp) = '2023-10-20'", sqlP)

				// ClickHouse
				sqlCH, _ := clickhouseTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM sweep_results WHERE toDate(timestamp) = '2023-10-20'", sqlCH)

				// ArangoDB
				aql, _ := arangoTranslator.Translate(query)
				expectedAQL := "FOR doc IN sweep_results\n  FILTER SUBSTRING(doc.timestamp, 0, 10) == '2023-10-20'\n  RETURN doc"
				assert.Equal(t, expectedAQL, aql)
			},
		},
		{
			name:  "Count sweep_results for TODAY",
			query: "count sweep_results where date(timestamp) = TODAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, models.Count, query.Type)
				assert.Equal(t, models.SweepResults, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "date(timestamp)", query.Conditions[0].Field)
				assert.Equal(t, "TODAY", query.Conditions[0].Value)

				// Proton
				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT COUNT(*) FROM table(sweep_results) WHERE to_date(timestamp) = today()", sqlP)
			},
		},
		{
			name:  "Show sweep_results with case-insensitive DATE function and TODAY keyword",
			query: "show sweep_results where DATE(timestamp) = today", // DATE and today are mixed case
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()

				require.NoError(t, err)
				assert.Equal(t, "date(timestamp)", query.Conditions[0].Field) // Visitor should lowercase func name
				assert.Equal(t, "TODAY", query.Conditions[0].Value)           // Visitor should normalize keyword

				sqlP, _ := protonTranslator.Translate(query)
				assert.Equal(t, "SELECT * FROM table(sweep_results) WHERE to_date(timestamp) = today()", sqlP)
			},
		},
		// Add more tests:
		// - Multiple conditions with date(timestamp) and other fields
		// - date(timestamp) with LATEST keyword (clarify expected behavior for LATEST with date filters)
		// - Ensure entity `sweep_results` is correctly recognized (may need grammar update for entity rule)
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
