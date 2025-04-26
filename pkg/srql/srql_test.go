package srql_test

import (
	"testing"

	"github.com/carverauto/serviceradar/pkg/srql/models"
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/stretchr/testify/assert"
)

func TestParseTimestamp(t *testing.T) {
	p := NewParser()
	query := "show devices where timestamp = '2023-12-25 14:30:00'"
	parsed, err := p.Parse(query)
	assert.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity)
	assert.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "timestamp", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "2023-12-25 14:30:00", parsed.Conditions[0].Value)
}

func TestParseIPAddress(t *testing.T) {
	p := NewParser()
	query := "show devices where ip = '192.168.1.1'"
	parsed, err := p.Parse(query)
	assert.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity)
	assert.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "ip", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "192.168.1.1", parsed.Conditions[0].Value)
}

func TestParseMACAddress(t *testing.T) {
	p := NewParser()
	query := "show devices where mac = '00:1A:2B:3C:4D:5E'"
	parsed, err := p.Parse(query)
	assert.NoError(t, err)
	assert.NotNil(t, parsed)
	assert.Equal(t, models.Show, parsed.Type)
	assert.Equal(t, models.Devices, parsed.Entity)
	assert.Len(t, parsed.Conditions, 1)
	assert.Equal(t, "mac", parsed.Conditions[0].Field)
	assert.Equal(t, models.Equals, parsed.Conditions[0].Operator)
	assert.Equal(t, "00:1A:2B:3C:4D:5E", parsed.Conditions[0].Value)
}

func TestSRQLParsing(t *testing.T) {
	// Create a parser
	p := parser.NewParser()

	// Test cases
	testCases := []struct {
		name          string
		query         string
		expectedError bool
		validate      func(t *testing.T, query *models.Query, err error)
	}{
		{
			name:          "Simple show query",
			query:         "show devices",
			expectedError: false,
			validate: func(t *testing.T, query *models.Query, err error) {
				assert.NoError(t, err)

				// Create translators
				clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)
				arangoTranslator := parser.NewTranslator(parser.ArangoDB)

				// Translate to SQL and AQL
				sql, err := clickhouseTranslator.Translate(query)
				assert.NoError(t, err)
				assert.Equal(t, "SELECT * FROM devices", sql)

				aql, err := arangoTranslator.Translate(query)
				assert.NoError(t, err)
				assert.Equal(t, "FOR doc IN devices\n  RETURN doc", aql)
			},
		},
		{
			name:          "Show query with condition",
			query:         "show devices where ip = '192.168.1.1'",
			expectedError: false,
			validate: func(t *testing.T, query *models.Query, err error) {
				assert.NoError(t, err)

				clickhouseTranslator := parser.NewTranslator(parser.ClickHouse)
				sql, err := clickhouseTranslator.Translate(query)
				assert.NoError(t, err)
				assert.Equal(t, "SELECT * FROM devices WHERE ip = '192.168.1.1'", sql)
			},
		},
		// ... other test cases remain the same but change function signature ...
		{
			name:          "Invalid query - syntax error",
			query:         "shoe devices", // 'shoe' instead of 'show'
			expectedError: true,
			validate: func(t *testing.T, query *models.Query, err error) {
				assert.Error(t, err)
				assert.Contains(t, err.Error(), "syntax error")
				assert.Nil(t, query)
			},
		},
		// ... other test cases ...
	}

	// Run test cases
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			query, err := p.Parse(tc.query)

			if tc.expectedError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}

			tc.validate(t, query, err)
		})
	}
}

// Test edge cases and specific features
func TestSRQLEdgeCases(t *testing.T) {
	p := parser.NewParser()

	// Test case-insensitivity
	upperQuery := "SHOW DEVICES WHERE IP = '192.168.1.1'"
	mixedQuery := "Show Devices Where Ip = '192.168.1.1'"

	upperResult, err1 := p.Parse(upperQuery)
	assert.NoError(t, err1)

	mixedResult, err2 := p.Parse(mixedQuery)
	assert.NoError(t, err2)

	translator := parser.NewTranslator(parser.ClickHouse)

	upperSQL, _ := translator.Translate(upperResult)
	mixedSQL, _ := translator.Translate(mixedResult)

	// Both should produce the same SQL
	assert.Equal(t, upperSQL, mixedSQL)
	assert.Equal(t, "SELECT * FROM devices WHERE ip = '192.168.1.1'", upperSQL)

	// ... rest of function ...
}
