package parser

import (
	"fmt"
	"github.com/carverauto/serviceradar/pkg/srql/models"
	"strings"
)

// DatabaseType defines the type of database we're translating to
type DatabaseType string

const (
	ClickHouse DatabaseType = "clickhouse"
	ArangoDB   DatabaseType = "arangodb"
)

// Translator converts a Query model to a database-specific query string
type Translator struct {
	DBType DatabaseType
}

// NewTranslator creates a new Translator
func NewTranslator(dbType DatabaseType) *Translator {
	return &Translator{
		DBType: dbType,
	}
}

// Translate converts a Query model to a database query string
func (t *Translator) Translate(query *models.Query) (string, error) {
	// Check for nil query
	if query == nil {
		return "", fmt.Errorf("cannot translate nil query")
	}

	if t.DBType == ClickHouse {
		return t.toClickHouseSQL(query)
	} else if t.DBType == ArangoDB {
		return t.toArangoDB(query)
	}

	return "", fmt.Errorf("unsupported database type: %s", t.DBType)
}

// toClickHouseSQL converts to ClickHouse SQL
func (t *Translator) toClickHouseSQL(query *models.Query) (string, error) {
	// Check for nil query again for safety
	if query == nil {
		return "", fmt.Errorf("cannot translate nil query to ClickHouse SQL")
	}

	var sql strings.Builder

	// Build the SELECT clause
	switch query.Type {
	case models.Show, models.Find:
		sql.WriteString("SELECT * FROM ")
	case models.Count:
		sql.WriteString("SELECT COUNT(*) FROM ")
	}

	// Add the table name
	sql.WriteString(strings.ToLower(string(query.Entity)))

	// Add WHERE clause if conditions exist
	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildClickHouseWhere(query.Conditions))
	}

	// Add ORDER BY clause if present
	if len(query.OrderBy) > 0 {
		sql.WriteString(" ORDER BY ")
		orderByParts := []string{}

		for _, item := range query.OrderBy {
			direction := "ASC"
			if item.Direction == models.Descending {
				direction = "DESC"
			}

			orderByParts = append(orderByParts, fmt.Sprintf("%s %s",
				strings.ToLower(item.Field), // Convert field name to lowercase
				direction))
		}

		sql.WriteString(strings.Join(orderByParts, ", "))
	}

	// Add LIMIT clause if present
	if query.HasLimit {
		sql.WriteString(fmt.Sprintf(" LIMIT %d", query.Limit))
	}

	return sql.String(), nil
}

// buildClickHouseWhere builds a WHERE clause for ClickHouse SQL
func (t *Translator) buildClickHouseWhere(conditions []models.Condition) string {
	if len(conditions) == 0 {
		return ""
	}

	var sql strings.Builder

	for i, cond := range conditions {
		// Add logical operator for conditions after the first
		if i > 0 {
			sql.WriteString(fmt.Sprintf(" %s ", cond.LogicalOp))
		}

		// Handle complex (nested) conditions
		if cond.IsComplex {
			sql.WriteString("(")
			sql.WriteString(t.buildClickHouseWhere(cond.Complex))
			sql.WriteString(")")
			continue
		}

		// Get lowercase field name for case insensitivity
		fieldName := strings.ToLower(cond.Field)

		// Handle different operators
		switch cond.Operator {
		case models.Equals, models.NotEquals, models.GreaterThan,
			models.GreaterThanOrEquals, models.LessThan, models.LessThanOrEquals:
			sql.WriteString(fmt.Sprintf("%s %s %s",
				fieldName,
				cond.Operator,
				t.formatClickHouseValue(cond.Value)))

		case models.Like:
			sql.WriteString(fmt.Sprintf("%s LIKE %s",
				fieldName,
				t.formatClickHouseValue(cond.Value)))

		case models.Contains:
			sql.WriteString(fmt.Sprintf("position(%s, %s) > 0",
				fieldName,
				t.formatClickHouseValue(cond.Value)))

		case models.In:
			values := []string{}
			for _, val := range cond.Values {
				values = append(values, t.formatClickHouseValue(val))
			}

			sql.WriteString(fmt.Sprintf("%s IN (%s)",
				fieldName,
				strings.Join(values, ", ")))

		case models.Between:
			if len(cond.Values) == 2 {
				sql.WriteString(fmt.Sprintf("%s BETWEEN %s AND %s",
					fieldName,
					t.formatClickHouseValue(cond.Values[0]),
					t.formatClickHouseValue(cond.Values[1])))
			}

		case models.Is:
			isNotNull, ok := cond.Value.(bool)
			if ok {
				if isNotNull {
					sql.WriteString(fmt.Sprintf("%s IS NOT NULL", fieldName))
				} else {
					sql.WriteString(fmt.Sprintf("%s IS NULL", fieldName))
				}
			}
		}
	}

	return sql.String()
}

// toArangoDB converts to ArangoDB AQL
func (t *Translator) toArangoDB(query *models.Query) (string, error) {
	// Check for nil query
	if query == nil {
		return "", fmt.Errorf("cannot translate nil query to ArangoDB AQL")
	}

	var aql strings.Builder

	// Start with the collection
	aql.WriteString(fmt.Sprintf("FOR doc IN %s", strings.ToLower(string(query.Entity))))

	// Add filter if conditions exist
	if len(query.Conditions) > 0 {
		aql.WriteString("\n  FILTER ")
		aql.WriteString(t.buildArangoDBFilter(query.Conditions))
	}

	// Add sort if order by exists
	if len(query.OrderBy) > 0 {
		aql.WriteString("\n  SORT ")
		sortParts := []string{}

		for _, item := range query.OrderBy {
			direction := "ASC"
			if item.Direction == models.Descending {
				direction = "DESC"
			}

			sortParts = append(sortParts, fmt.Sprintf("doc.%s %s",
				strings.ToLower(item.Field), // Convert field name to lowercase
				direction))
		}

		aql.WriteString(strings.Join(sortParts, ", "))
	}

	// Add limit if present
	if query.HasLimit {
		aql.WriteString(fmt.Sprintf("\n  LIMIT %d", query.Limit))
	}

	// Add return clause based on query type
	switch query.Type {
	case models.Show, models.Find:
		aql.WriteString("\n  RETURN doc")
	case models.Count:
		// Wrap the whole query in a count
		countAQL := fmt.Sprintf("RETURN LENGTH(\n%s\n)", aql.String())
		return countAQL, nil
	}

	return aql.String(), nil
}

// buildArangoDBFilter builds a FILTER clause for ArangoDB AQL
func (t *Translator) buildArangoDBFilter(conditions []models.Condition) string {
	if len(conditions) == 0 {
		return ""
	}

	var aql strings.Builder

	for i, cond := range conditions {
		// Add logical operator for conditions after the first
		if i > 0 {
			aql.WriteString(fmt.Sprintf(" %s ", cond.LogicalOp))
		}

		// Handle complex (nested) conditions
		if cond.IsComplex {
			aql.WriteString("(")
			aql.WriteString(t.buildArangoDBFilter(cond.Complex))
			aql.WriteString(")")
			continue
		}

		// Get lowercase field name for case insensitivity
		fieldName := strings.ToLower(cond.Field)

		// Handle different operators
		switch cond.Operator {
		case models.Equals:
			aql.WriteString(fmt.Sprintf("doc.%s == %s",
				fieldName,
				t.formatArangoDBValue(cond.Value)))

		case models.NotEquals:
			aql.WriteString(fmt.Sprintf("doc.%s != %s",
				fieldName,
				t.formatArangoDBValue(cond.Value)))

		case models.GreaterThan, models.GreaterThanOrEquals,
			models.LessThan, models.LessThanOrEquals:
			aql.WriteString(fmt.Sprintf("doc.%s %s %s",
				fieldName,
				t.translateOperator(cond.Operator),
				t.formatArangoDBValue(cond.Value)))

		case models.Like:
			aql.WriteString(fmt.Sprintf("LIKE(doc.%s, %s, true)",
				fieldName,
				t.formatArangoDBValue(cond.Value)))

		case models.Contains:
			aql.WriteString(fmt.Sprintf("CONTAINS(doc.%s, %s)",
				fieldName,
				t.formatArangoDBValue(cond.Value)))

		case models.In:
			values := []string{}
			for _, val := range cond.Values {
				values = append(values, t.formatArangoDBValue(val))
			}

			aql.WriteString(fmt.Sprintf("doc.%s IN [%s]",
				fieldName,
				strings.Join(values, ", ")))

		case models.Between:
			if len(cond.Values) == 2 {
				aql.WriteString(fmt.Sprintf("doc.%s >= %s AND doc.%s <= %s",
					fieldName,
					t.formatArangoDBValue(cond.Values[0]),
					fieldName,
					t.formatArangoDBValue(cond.Values[1])))
			}

		case models.Is:
			isNotNull, ok := cond.Value.(bool)
			if ok {
				if isNotNull {
					aql.WriteString(fmt.Sprintf("doc.%s != null", fieldName))
				} else {
					aql.WriteString(fmt.Sprintf("doc.%s == null", fieldName))
				}
			}
		}
	}

	return aql.String()
}

// Helper methods for formatting values

func (t *Translator) formatClickHouseValue(value interface{}) string {
	switch v := value.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		if v {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", v)
	}
}

func (t *Translator) formatArangoDBValue(value interface{}) string {
	switch v := value.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		if v {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", v)
	}
}

func (t *Translator) translateOperator(op models.OperatorType) string {
	switch op {
	case models.GreaterThan:
		return ">"
	case models.GreaterThanOrEquals:
		return ">="
	case models.LessThan:
		return "<"
	case models.LessThanOrEquals:
		return "<="
	default:
		return string(op)
	}
}
