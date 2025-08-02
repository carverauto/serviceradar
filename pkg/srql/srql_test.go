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

func TestTodayYesterdayParsing(t *testing.T) {
	p := parser.NewParser()

	testCases := []struct {
		name          string
		query         string
		expectedError bool
		validate      func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:  "COUNT with TODAY comparison",
			query: "COUNT events WHERE _tp_time > TODAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Count, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "_tp_time", query.Conditions[0].Field)
				assert.Equal(t, models.GreaterThan, query.Conditions[0].Operator)
				assert.Equal(t, "TODAY", query.Conditions[0].Value)
			},
		},
		{
			name:  "SHOW with TODAY equals",
			query: "SHOW events WHERE _tp_time = TODAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "_tp_time", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, "TODAY", query.Conditions[0].Value)
			},
		},
		{
			name:  "SHOW with YESTERDAY comparison",
			query: "SHOW cpu_metrics WHERE _tp_time >= YESTERDAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.CPUMetrics, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "_tp_time", query.Conditions[0].Field)
				assert.Equal(t, models.GreaterThanOrEquals, query.Conditions[0].Operator)
				assert.Equal(t, "YESTERDAY", query.Conditions[0].Value)
			},
		},
		{
			name:  "date() function with TODAY",
			query: "COUNT events WHERE date(_tp_time) = TODAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Count, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "date(_tp_time)", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, "TODAY", query.Conditions[0].Value)
			},
		},
		{
			name:  "timestamp field with TODAY",
			query: "SHOW cpu_metrics WHERE timestamp > TODAY",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.CPUMetrics, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "timestamp", query.Conditions[0].Field)
				assert.Equal(t, models.GreaterThan, query.Conditions[0].Operator)
				assert.Equal(t, "TODAY", query.Conditions[0].Value)
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			parsedQuery, err := p.Parse(tc.query)
			if tc.expectedError {
				require.Error(t, err)
			} else {
				require.NoError(t, err, "Query parsing failed unexpectedly")
			}

			tc.validate(t, parsedQuery, err)
		})
	}
}

func TestTodayYesterdayTranslation(t *testing.T) {
	p := parser.NewParser()

	// Define translators
	protonTranslator := parser.NewTranslator(parser.Proton)
	clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)

	testCases := []struct {
		name               string
		query              string
		expectedProton     string
		expectedClickHouse string
	}{
		{
			name:               "TODAY with greater than",
			query:              "COUNT events WHERE _tp_time > TODAY",
			expectedProton:     "SELECT count() FROM table(events) WHERE _tp_time > today()",
			expectedClickHouse: "SELECT count() FROM events WHERE _tp_time > today()",
		},
		{
			name:               "TODAY with equals",
			query:              "SHOW events WHERE _tp_time = TODAY",
			expectedProton:     "SELECT * FROM table(events) WHERE _tp_time = today()",
			expectedClickHouse: "SELECT * FROM events WHERE _tp_time = today()",
		},
		{
			name:               "YESTERDAY with greater than or equals",
			query:              "SHOW cpu_metrics WHERE _tp_time >= YESTERDAY",
			expectedProton:     "SELECT * FROM table(cpu_metrics) WHERE _tp_time >= yesterday()",
			expectedClickHouse: "SELECT * FROM cpu_metrics WHERE _tp_time >= yesterday()",
		},
		{
			name:               "timestamp field with TODAY",
			query:              "SHOW cpu_metrics WHERE timestamp > TODAY",
			expectedProton:     "SELECT * FROM table(cpu_metrics) WHERE timestamp > today()",
			expectedClickHouse: "SELECT * FROM cpu_metrics WHERE timestamp > today()",
		},
		{
			name:               "date() function with TODAY",
			query:              "COUNT events WHERE date(_tp_time) = TODAY",
			expectedProton:     "SELECT count() FROM table(events) WHERE to_date(_tp_time) = today()",
			expectedClickHouse: "SELECT count() FROM events WHERE toDate(_tp_time) = today()",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			parsedQuery, err := p.Parse(tc.query)
			require.NoError(t, err, "Query parsing failed")

			// Test Proton translation
			if tc.expectedProton != "" {
				sqlProton, errProton := protonTranslator.Translate(parsedQuery)
				require.NoError(t, errProton, "Proton translation failed")
				assert.Equal(t, tc.expectedProton, sqlProton, "Proton SQL mismatch")
			}

			// Test ClickHouse translation
			if tc.expectedClickHouse != "" {
				sqlClickHouse, errClickHouse := clickhouseTranslator.Translate(parsedQuery)
				require.NoError(t, errClickHouse, "ClickHouse translation failed")
				assert.Equal(t, tc.expectedClickHouse, sqlClickHouse, "ClickHouse SQL mismatch")
			}
		})
	}
}

func TestLogsSeverityFieldMapping(t *testing.T) {
	p := parser.NewParser()
	protonTranslator := parser.NewTranslator(parser.Proton)
	clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)

	testCases := []struct {
		name               string
		query              string
		expectedProton     string
		expectedClickHouse string
	}{
		{
			name:               "severity field mapping in logs",
			query:              "SHOW logs WHERE severity = 'warn'",
			expectedProton:     "SELECT * FROM table(logs) WHERE severity_text = 'warn'",
			expectedClickHouse: "SELECT * FROM logs WHERE severity_text = 'warn'",
		},
		{
			name:               "level field mapping in logs (synonym for severity)",
			query:              "SHOW logs WHERE level = 'error'",
			expectedProton:     "SELECT * FROM table(logs) WHERE severity_text = 'error'",
			expectedClickHouse: "SELECT * FROM logs WHERE severity_text = 'error'",
		},
		{
			name:               "severity_text field should remain unchanged",
			query:              "SHOW logs WHERE severity_text = 'info'",
			expectedProton:     "SELECT * FROM table(logs) WHERE severity_text = 'info'",
			expectedClickHouse: "SELECT * FROM logs WHERE severity_text = 'info'",
		},
		{
			name:               "severity field with ORDER BY",
			query:              "SHOW logs WHERE severity = 'warn' ORDER BY _tp_time DESC LIMIT 50",
			expectedProton:     "SELECT * FROM table(logs) WHERE severity_text = 'warn' ORDER BY _tp_time DESC LIMIT 50",
			expectedClickHouse: "SELECT * FROM logs WHERE severity_text = 'warn' ORDER BY _tp_time DESC LIMIT 50",
		},
		{
			name:               "multiple conditions with severity mapping",
			query:              "SHOW logs WHERE severity = 'error' AND service_name = 'test'",
			expectedProton:     "SELECT * FROM table(logs) WHERE severity_text = 'error' AND service_name = 'test'",
			expectedClickHouse: "SELECT * FROM logs WHERE severity_text = 'error' AND service_name = 'test'",
		},
		{
			name:               "service field mapping in logs",
			query:              "SHOW logs WHERE service = 'serviceradar-sync'",
			expectedProton:     "SELECT * FROM table(logs) WHERE service_name = 'serviceradar-sync'",
			expectedClickHouse: "SELECT * FROM logs WHERE service_name = 'serviceradar-sync'",
		},
		{
			name:               "service_name field should remain unchanged",
			query:              "SHOW logs WHERE service_name = 'serviceradar-sync'",
			expectedProton:     "SELECT * FROM table(logs) WHERE service_name = 'serviceradar-sync'",
			expectedClickHouse: "SELECT * FROM logs WHERE service_name = 'serviceradar-sync'",
		},
		{
			name:  "service field with time clause",
			query: "SHOW logs FROM YESTERDAY WHERE service = 'serviceradar-sync' AND severity = 'info'",
			expectedProton: "SELECT * FROM table(logs) WHERE timestamp BETWEEN to_start_of_day(yesterday()) " +
				"AND to_start_of_day(today()) AND service_name = 'serviceradar-sync' AND severity_text = 'info'",
			expectedClickHouse: "SELECT * FROM logs WHERE timestamp BETWEEN to_start_of_day(yesterday()) " +
				"AND to_start_of_day(today()) AND service_name = 'serviceradar-sync' AND severity_text = 'info'",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			parsedQuery, err := p.Parse(tc.query)
			require.NoError(t, err, "Query parsing failed for: %s", tc.query)

			// Test Proton translation
			sqlProton, errProton := protonTranslator.Translate(parsedQuery)
			require.NoError(t, errProton, "Proton translation failed")
			assert.Equal(t, tc.expectedProton, sqlProton, "Proton SQL mismatch")

			// Test ClickHouse translation
			sqlClickHouse, errClickHouse := clickhouseTranslator.Translate(parsedQuery)
			require.NoError(t, errClickHouse, "ClickHouse translation failed")
			assert.Equal(t, tc.expectedClickHouse, sqlClickHouse, "ClickHouse SQL mismatch")
		})
	}
}

func TestTimeClauseSupport(t *testing.T) {
	p := parser.NewParser()
	protonTranslator := parser.NewTranslator(parser.Proton)
	clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)

	testCases := []struct {
		name               string
		query              string
		expectedProton     string
		expectedClickHouse string
		validate           func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:               "FROM YESTERDAY simple",
			query:              "SHOW logs FROM YESTERDAY",
			expectedProton:     "SELECT * FROM table(logs) WHERE timestamp BETWEEN to_start_of_day(yesterday()) AND to_start_of_day(today())",
			expectedClickHouse: "SELECT * FROM logs WHERE timestamp BETWEEN toStartOfDay(yesterday()) AND toStartOfDay(today())",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Logs, query.Entity)
				// Should have a TimeClause before translation
				require.NotNil(t, query.TimeClause)
				assert.Equal(t, models.TimeYesterday, query.TimeClause.Type)
			},
		},
		{
			name:  "FROM TODAY with additional conditions",
			query: "SHOW devices FROM TODAY WHERE ip = '192.168.1.1'",
			expectedProton: "SELECT * FROM table(unified_devices) WHERE " +
				"(last_seen >= to_start_of_day(now()) AND ip = '192.168.1.1') AND " +
				"coalesce(metadata['_deleted'], '') != 'true'",
			expectedClickHouse: "SELECT * FROM devices WHERE last_seen >= toStartOfDay(now()) AND ip = '192.168.1.1'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Devices, query.Entity)
				// Should have a TimeClause and one condition (IP)
				require.NotNil(t, query.TimeClause)
				assert.Equal(t, models.TimeToday, query.TimeClause.Type)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "ip", query.Conditions[0].Field)
				assert.Equal(t, "192.168.1.1", query.Conditions[0].Value)
			},
		},
		{
			name:  "COUNT events FROM YESTERDAY",
			query: "COUNT events FROM YESTERDAY",
			expectedProton: "SELECT count() FROM table(events) WHERE timestamp BETWEEN " +
				"to_start_of_day(yesterday()) AND to_start_of_day(today())",
			expectedClickHouse: "SELECT count() FROM events WHERE timestamp BETWEEN toStartOfDay(yesterday()) AND toStartOfDay(today())",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Count, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				require.NotNil(t, query.TimeClause)
				assert.Equal(t, models.TimeYesterday, query.TimeClause.Type)
			},
		},
		{
			name:               "LAST 5 DAYS syntax",
			query:              "SHOW logs FROM LAST 5 DAYS",
			expectedProton:     "SELECT * FROM table(logs) WHERE timestamp >= NOW() - INTERVAL 5 DAYS",
			expectedClickHouse: "SELECT * FROM logs WHERE timestamp >= NOW() - INTERVAL 5 DAYS",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Logs, query.Entity)
				require.NotNil(t, query.TimeClause)
				assert.Equal(t, models.TimeLast, query.TimeClause.Type)
				assert.Equal(t, 5, query.TimeClause.Amount)
				assert.Equal(t, models.UnitDays, query.TimeClause.Unit)
			},
		},
		{
			name:               "LAST 2 HOURS syntax",
			query:              "SHOW events FROM LAST 2 HOURS",
			expectedProton:     "SELECT * FROM table(events) WHERE timestamp >= NOW() - INTERVAL 2 HOURS",
			expectedClickHouse: "SELECT * FROM events WHERE timestamp >= NOW() - INTERVAL 2 HOURS",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.Events, query.Entity)
				require.NotNil(t, query.TimeClause)
				assert.Equal(t, models.TimeLast, query.TimeClause.Type)
				assert.Equal(t, 2, query.TimeClause.Amount)
				assert.Equal(t, models.UnitHours, query.TimeClause.Unit)
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			parsedQuery, err := p.Parse(tc.query)

			if tc.validate != nil {
				tc.validate(t, parsedQuery, err)
			} else {
				require.NoError(t, err, "Query parsing failed for: %s", tc.query)
			}

			// Test Proton translation
			if tc.expectedProton != "" {
				// Parse a fresh copy for Proton
				protonQuery, errProtonParse := p.Parse(tc.query)
				require.NoError(t, errProtonParse, "Proton query parsing failed")

				sqlProton, errProton := protonTranslator.Translate(protonQuery)
				require.NoError(t, errProton, "Proton translation failed")
				assert.Equal(t, tc.expectedProton, sqlProton, "Proton SQL mismatch")
			}

			// Test ClickHouse translation
			if tc.expectedClickHouse != "" {
				// Parse a fresh copy for ClickHouse
				clickhouseQuery, errClickHouseParse := p.Parse(tc.query)
				require.NoError(t, errClickHouseParse, "ClickHouse query parsing failed")

				sqlClickHouse, errClickHouse := clickhouseTranslator.Translate(clickhouseQuery)
				require.NoError(t, errClickHouse, "ClickHouse translation failed")
				assert.Equal(t, tc.expectedClickHouse, sqlClickHouse, "ClickHouse SQL mismatch")
			}
		})
	}
}

func TestOTELEntities(t *testing.T) {
	p := parser.NewParser()
	protonTranslator := parser.NewTranslator(parser.Proton)

	tests := []struct {
		name     string
		query    string
		validate func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:  "Find OTEL traces simple query",
			query: "FIND otel_traces",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelTraces, query.Entity)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_traces)", sql)
			},
		},
		{
			name:  "Find OTEL metrics simple query",
			query: "FIND otel_metrics",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelMetrics, query.Entity)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_metrics)", sql)
			},
		},
		{
			name:  "Find OTEL trace summaries simple query",
			query: "FIND otel_trace_summaries",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelTraceSummaries, query.Entity)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_trace_summaries)", sql)
			},
		},
		{
			name:  "Find OTEL traces with trace ID correlation",
			query: "FIND otel_traces WHERE trace = 'abc123'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelTraces, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "trace", query.Conditions[0].Field)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_traces) WHERE trace_id = 'abc123'", sql)
			},
		},
		{
			name:  "Find OTEL trace summaries with service and duration filter",
			query: "FIND otel_trace_summaries WHERE service = 'checkout' AND duration_ms > 250",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelTraceSummaries, query.Entity)
				require.Len(t, query.Conditions, 2)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_trace_summaries) WHERE root_service_name = 'checkout' AND duration_ms > 250", sql)
			},
		},
		{
			name:  "Find OTEL traces with computed duration_ms",
			query: "FIND otel_traces WHERE duration_ms > 100",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.OtelTraces, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "duration_ms", query.Conditions[0].Field)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(otel_traces) WHERE (end_time_unix_nano - start_time_unix_nano) / 1e6 > 100", sql)
			},
		},
		{
			name:  "Find logs with trace correlation",
			query: "FIND logs WHERE trace = 'abc123'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Find, query.Type)
				assert.Equal(t, models.Logs, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "trace", query.Conditions[0].Field)

				sql, errT := protonTranslator.Translate(query)
				require.NoError(t, errT)
				assert.Equal(t, "SELECT * FROM table(logs) WHERE trace_id = 'abc123'", sql)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			query, err := p.Parse(tt.query)
			tt.validate(t, query, err)
		})
	}
}

func TestBooleanComparisons(t *testing.T) {
	p := parser.NewParser()
	protonTranslator := parser.NewTranslator(parser.Proton)
	clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)

	tests := []struct {
		name               string
		query              string
		expectedProton     string
		expectedClickHouse string
		validate           func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:               "Boolean field equals true",
			query:              "SHOW otel_metrics WHERE is_slow = true",
			expectedProton:     "SELECT * FROM table(otel_metrics) WHERE is_slow = 1",
			expectedClickHouse: "SELECT * FROM otel_metrics WHERE is_slow = 1",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.OtelMetrics, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "is_slow", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, true, query.Conditions[0].Value)
			},
		},
		{
			name:               "Boolean field equals false",
			query:              "SHOW otel_metrics WHERE is_slow = false",
			expectedProton:     "SELECT * FROM table(otel_metrics) WHERE is_slow = 0",
			expectedClickHouse: "SELECT * FROM otel_metrics WHERE is_slow = 0",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.OtelMetrics, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "is_slow", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, false, query.Conditions[0].Value)
			},
		},
		{
			name:               "Count with boolean condition",
			query:              "COUNT otel_metrics WHERE is_slow = true",
			expectedProton:     "SELECT count() FROM table(otel_metrics) WHERE is_slow = 1",
			expectedClickHouse: "SELECT count() FROM otel_metrics WHERE is_slow = 1",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Count, query.Type)
				assert.Equal(t, models.OtelMetrics, query.Entity)
				require.Len(t, query.Conditions, 1)
				assert.Equal(t, "is_slow", query.Conditions[0].Field)
				assert.Equal(t, models.Equals, query.Conditions[0].Operator)
				assert.Equal(t, true, query.Conditions[0].Value)
			},
		},
		{
			name:               "Boolean with other conditions",
			query:              "SHOW otel_metrics WHERE is_slow = true AND service_name = 'test'",
			expectedProton:     "SELECT * FROM table(otel_metrics) WHERE is_slow = 1 AND service_name = 'test'",
			expectedClickHouse: "SELECT * FROM otel_metrics WHERE is_slow = 1 AND service_name = 'test'",
			validate: func(t *testing.T, query *models.Query, err error) {
				t.Helper()
				require.NoError(t, err)
				assert.Equal(t, models.Show, query.Type)
				assert.Equal(t, models.OtelMetrics, query.Entity)
				require.Len(t, query.Conditions, 2)
				assert.Equal(t, "is_slow", query.Conditions[0].Field)
				assert.Equal(t, true, query.Conditions[0].Value)
				assert.Equal(t, "service_name", query.Conditions[1].Field)
				assert.Equal(t, "test", query.Conditions[1].Value)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			query, err := p.Parse(tt.query)
			
			if tt.validate != nil {
				tt.validate(t, query, err)
			} else {
				require.NoError(t, err, "Query parsing failed for: %s", tt.query)
			}

			// Test Proton translation
			if tt.expectedProton != "" {
				sqlProton, errProton := protonTranslator.Translate(query)
				require.NoError(t, errProton, "Proton translation failed")
				assert.Equal(t, tt.expectedProton, sqlProton, "Proton SQL mismatch")
			}

			// Test ClickHouse translation
			if tt.expectedClickHouse != "" {
				sqlClickHouse, errClickHouse := clickhouseTranslator.Translate(query)
				require.NoError(t, errClickHouse, "ClickHouse translation failed")
				assert.Equal(t, tt.expectedClickHouse, sqlClickHouse, "ClickHouse SQL mismatch")
			}
		})
	}
}
