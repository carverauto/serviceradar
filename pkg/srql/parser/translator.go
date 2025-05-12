package parser

import (
	"fmt"
	"strings"

	"github.com/carverauto/serviceradar/pkg/srql/models"
)

// DatabaseType defines the type of database we're translating to
type DatabaseType string

const (
	ClickHouse DatabaseType = "clickhouse"
	Proton     DatabaseType = "proton"
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
		return "", errCannotTranslateNilQuery
	}

	if t.DBType == ClickHouse {
		return t.toClickHouseSQL(query)
	} else if t.DBType == ArangoDB {
		return t.toArangoDB(query)
	} else if t.DBType == Proton {
		return t.toProtonSQL(query)
	}

	return "", fmt.Errorf("%w for database type: %s", errUnsupportedDatabaseType, t.DBType)
}

const (
	defaultAscending  = "ASC"
	defaultDescending = "DESC"
)

// toProtonSQL converts to Proton SQL
// toProtonSQL converts to Proton SQL
func (t *Translator) toProtonSQL(query *models.Query) (string, error) {
	// Check for nil query again for safety
	if query == nil {
		return "", errCannotTranslateNilQueryProton
	}

	var sql strings.Builder

	// Build the SELECT clause
	switch query.Type {
	case models.Show, models.Find:
		sql.WriteString("SELECT * FROM ")
	case models.Count:
		sql.WriteString("SELECT COUNT(*) FROM ")
	}

	// Add the stream name directly without table() function
	sql.WriteString(strings.ToLower(string(query.Entity)))

	// Add WHERE clause if conditions exist
	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildProtonWhere(query.Conditions))
	}

	// Add ORDER BY clause if present
	if len(query.OrderBy) > 0 {
		sql.WriteString(" ORDER BY ")

		var orderByParts []string

		for _, item := range query.OrderBy {
			direction := defaultAscending
			if item.Direction == models.Descending {
				direction = defaultDescending
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

// buildProtonWhere builds a WHERE clause for Proton SQL
func (t *Translator) buildProtonWhere(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		t.formatProtonCondition,
		t.buildProtonWhere,
	)
}

// formatProtonCondition formats a single condition for Proton SQL
func (t *Translator) formatProtonCondition(cond *models.Condition) string {
	// Get lowercase field name for case insensitivity
	fieldName := strings.ToLower(cond.Field)

	// Handle different operators by operator type
	switch {
	case t.isComparisonOperator(cond.Operator):
		return t.formatComparisonCondition(fieldName, cond.Operator, cond.Value)
	case cond.Operator == models.Like:
		return t.formatProtonLikeCondition(fieldName, cond.Value)
	case cond.Operator == models.Contains:
		return t.formatProtonContainsCondition(fieldName, cond.Value)
	case cond.Operator == models.In:
		return t.formatProtonInCondition(fieldName, cond.Values)
	case cond.Operator == models.Between:
		return t.formatProtonBetweenCondition(fieldName, cond.Values)
	case cond.Operator == models.Is:
		return t.formatProtonIsCondition(fieldName, cond.Value)
	default:
		return ""
	}
}

// formatProtonLikeCondition formats a LIKE condition
func (t *Translator) formatProtonLikeCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("%s LIKE %s", fieldName, t.formatProtonValue(value))
}

// formatProtonContainsCondition formats a CONTAINS condition
func (t *Translator) formatProtonContainsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("position(%s, %s) > 0", fieldName, t.formatProtonValue(value))
}

// formatProtonInCondition formats an IN condition
func (t *Translator) formatProtonInCondition(fieldName string, values []interface{}) string {
	formattedValues := make([]string, 0, len(values))

	for _, val := range values {
		formattedValues = append(formattedValues, t.formatProtonValue(val))
	}

	return fmt.Sprintf("%s IN (%s)", fieldName, strings.Join(formattedValues, ", "))
}

// formatProtonBetweenCondition formats a BETWEEN condition
func (t *Translator) formatProtonBetweenCondition(fieldName string, values []interface{}) string {
	if len(values) == defaultModelsBetween {
		return fmt.Sprintf("%s BETWEEN %s AND %s",
			fieldName,
			t.formatProtonValue(values[0]),
			t.formatProtonValue(values[1]))
	}

	return ""
}

// formatProtonIsCondition formats an IS NULL or IS NOT NULL condition
func (*Translator) formatProtonIsCondition(fieldName string, value interface{}) string {
	isNotNull, ok := value.(bool)
	if ok {
		if isNotNull {
			return fmt.Sprintf("%s IS NOT NULL", fieldName)
		}

		return fmt.Sprintf("%s IS NULL", fieldName)
	}

	return ""
}

// formatProtonValue formats a value for Proton SQL
func (*Translator) formatProtonValue(value interface{}) string {
	switch v := value.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		if v {
			return defaultBoolValueTrue
		}

		return defaultBoolValueFalse
	default:
		return fmt.Sprintf("%v", v)
	}
}

// toClickHouseSQL converts to ClickHouse SQL
func (t *Translator) toClickHouseSQL(query *models.Query) (string, error) {
	// Check for nil query again for safety
	if query == nil {
		return "", errCannotTranslateNilQueryClickHouse
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

		var orderByParts []string

		for _, item := range query.OrderBy {
			direction := defaultAscending
			if item.Direction == models.Descending {
				direction = defaultDescending
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

// formatClickHouseCondition formats a single condition for ClickHouse SQL
func (t *Translator) formatClickHouseCondition(cond *models.Condition) string {
	// Get lowercase field name for case insensitivity
	fieldName := strings.ToLower(cond.Field)

	// Handle different operators by operator type
	switch {
	case t.isComparisonOperator(cond.Operator):
		return t.formatComparisonCondition(fieldName, cond.Operator, cond.Value)
	case cond.Operator == models.Like:
		return t.formatLikeCondition(fieldName, cond.Value)
	case cond.Operator == models.Contains:
		return t.formatContainsCondition(fieldName, cond.Value)
	case cond.Operator == models.In:
		return t.formatInCondition(fieldName, cond.Values)
	case cond.Operator == models.Between:
		return t.formatBetweenCondition(fieldName, cond.Values)
	case cond.Operator == models.Is:
		return t.formatIsCondition(fieldName, cond.Value)
	default:
		return ""
	}
}

// isComparisonOperator checks if the operator is a basic comparison operator
func (*Translator) isComparisonOperator(op models.OperatorType) bool {
	return op == models.Equals || op == models.NotEquals ||
		op == models.GreaterThan || op == models.GreaterThanOrEquals ||
		op == models.LessThan || op == models.LessThanOrEquals
}

// formatComparisonCondition formats a basic comparison condition
func (t *Translator) formatComparisonCondition(fieldName string, op models.OperatorType, value interface{}) string {
	return fmt.Sprintf("%s %s %s", fieldName, op, t.formatClickHouseValue(value))
}

// formatLikeCondition formats a LIKE condition
func (t *Translator) formatLikeCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("%s LIKE %s", fieldName, t.formatClickHouseValue(value))
}

// formatContainsCondition formats a CONTAINS condition
func (t *Translator) formatContainsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("position(%s, %s) > 0", fieldName, t.formatClickHouseValue(value))
}

// formatInCondition formats an IN condition
func (t *Translator) formatInCondition(fieldName string, values []interface{}) string {
	formattedValues := make([]string, 0, len(values))

	for _, val := range values {
		formattedValues = append(formattedValues, t.formatClickHouseValue(val))
	}

	return fmt.Sprintf("%s IN (%s)", fieldName, strings.Join(formattedValues, ", "))
}

// formatBetweenCondition formats a BETWEEN condition
func (t *Translator) formatBetweenCondition(fieldName string, values []interface{}) string {
	if len(values) == defaultModelsBetween {
		return fmt.Sprintf("%s BETWEEN %s AND %s",
			fieldName,
			t.formatClickHouseValue(values[0]),
			t.formatClickHouseValue(values[1]))
	}

	return ""
}

// formatIsCondition formats an IS NULL or IS NOT NULL condition
func (*Translator) formatIsCondition(fieldName string, value interface{}) string {
	isNotNull, ok := value.(bool)
	if ok {
		if isNotNull {
			return fmt.Sprintf("%s IS NOT NULL", fieldName)
		}

		return fmt.Sprintf("%s IS NULL", fieldName)
	}

	return ""
}

// toArangoDB converts to ArangoDB AQL
func (t *Translator) toArangoDB(query *models.Query) (string, error) {
	// Check for nil query
	if query == nil {
		return "", errCannotTranslateNilQueryArangoDB
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

		var sortParts []string

		for _, item := range query.OrderBy {
			direction := defaultAscending
			if item.Direction == models.Descending {
				direction = defaultDescending
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

const (
	defaultModelsBetween = 2
)

// buildConditionString is a generic method to build condition strings for different databases
func (*Translator) buildConditionString(
	conditions []models.Condition,
	formatCondition func(*models.Condition) string,
	recursiveBuild func([]models.Condition) string) string {
	if len(conditions) == 0 {
		return ""
	}

	var builder strings.Builder

	for i, cond := range conditions {
		// Add logical operator for conditions after the first
		if i > 0 {
			builder.WriteString(fmt.Sprintf(" %s ", cond.LogicalOp))
		}

		// Handle complex (nested) conditions
		if cond.IsComplex {
			builder.WriteString("(")
			builder.WriteString(recursiveBuild(cond.Complex))
			builder.WriteString(")")

			continue
		}

		// Format the condition based on its operator
		builder.WriteString(formatCondition(&cond))
	}

	return builder.String()
}

// buildClickHouseWhere builds a WHERE clause for ClickHouse SQL
func (t *Translator) buildClickHouseWhere(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		t.formatClickHouseCondition,
		t.buildClickHouseWhere,
	)
}

// buildArangoDBFilter builds a FILTER clause for ArangoDB AQL
func (t *Translator) buildArangoDBFilter(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		t.formatArangoDBCondition,
		t.buildArangoDBFilter,
	)
}

// formatArangoDBCondition formats a single condition for ArangoDB AQL
func (t *Translator) formatArangoDBCondition(cond *models.Condition) string {
	// Get lowercase field name for case insensitivity
	fieldName := strings.ToLower(cond.Field)

	// Handle different operators by operator type
	switch cond.Operator {
	case models.Equals:
		return t.formatArangoDBEqualsCondition(fieldName, cond.Value)
	case models.NotEquals:
		return t.formatArangoDBNotEqualsCondition(fieldName, cond.Value)
	case models.GreaterThan, models.GreaterThanOrEquals, models.LessThan, models.LessThanOrEquals:
		return t.formatArangoDBComparisonCondition(fieldName, cond.Operator, cond.Value)
	case models.Like:
		return t.formatArangoDBLikeCondition(fieldName, cond.Value)
	case models.Contains:
		return t.formatArangoDBContainsCondition(fieldName, cond.Value)
	case models.In:
		return t.formatArangoDBInCondition(fieldName, cond.Values)
	case models.Between:
		return t.formatArangoDBBetweenCondition(fieldName, cond.Values)
	case models.Is:
		return t.formatArangoDBIsCondition(fieldName, cond.Value)
	default:
		return ""
	}
}

// formatArangoDBEqualsCondition formats an equals condition
func (t *Translator) formatArangoDBEqualsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("doc.%s == %s", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBNotEqualsCondition formats a not equals condition
func (t *Translator) formatArangoDBNotEqualsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("doc.%s != %s", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBComparisonCondition formats a comparison condition (>, >=, <, <=)
func (t *Translator) formatArangoDBComparisonCondition(fieldName string, op models.OperatorType, value interface{}) string {
	return fmt.Sprintf("doc.%s %s %s", fieldName, t.translateOperator(op), t.formatArangoDBValue(value))
}

// formatArangoDBLikeCondition formats a LIKE condition
func (t *Translator) formatArangoDBLikeCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("LIKE(doc.%s, %s, true)", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBContainsCondition formats a CONTAINS condition
func (t *Translator) formatArangoDBContainsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("CONTAINS(doc.%s, %s)", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBInCondition formats an IN condition
func (t *Translator) formatArangoDBInCondition(fieldName string, values []interface{}) string {
	formattedValues := make([]string, 0, len(values))

	for _, val := range values {
		formattedValues = append(formattedValues, t.formatArangoDBValue(val))
	}

	return fmt.Sprintf("doc.%s IN [%s]", fieldName, strings.Join(formattedValues, ", "))
}

// formatArangoDBBetweenCondition formats a BETWEEN condition
func (t *Translator) formatArangoDBBetweenCondition(fieldName string, values []interface{}) string {
	if len(values) == defaultModelsBetween {
		return fmt.Sprintf("doc.%s >= %s AND doc.%s <= %s",
			fieldName,
			t.formatArangoDBValue(values[0]),
			fieldName,
			t.formatArangoDBValue(values[1]))
	}

	return ""
}

// formatArangoDBIsCondition formats an IS NULL or IS NOT NULL condition
func (*Translator) formatArangoDBIsCondition(fieldName string, value interface{}) string {
	isNotNull, ok := value.(bool)
	if ok {
		if isNotNull {
			return fmt.Sprintf("doc.%s != null", fieldName)
		}

		return fmt.Sprintf("doc.%s == null", fieldName)
	}

	return ""
}

// Helper methods for formatting values

const (
	defaultBoolValueTrue  = "true"
	defaultBoolValueFalse = "false"
)

func (*Translator) formatClickHouseValue(value interface{}) string {
	switch v := value.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		if v {
			return defaultBoolValueTrue
		}

		return defaultBoolValueFalse
	default:
		return fmt.Sprintf("%v", v)
	}
}

func (*Translator) formatArangoDBValue(value interface{}) string {
	switch v := value.(type) {
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		if v {
			return defaultBoolValueTrue
		}

		return defaultBoolValueFalse
	default:
		return fmt.Sprintf("%v", v)
	}
}

func (*Translator) translateOperator(op models.OperatorType) string {
	operatorMap := map[models.OperatorType]string{
		models.Equals:              "=",
		models.NotEquals:           "!=",
		models.GreaterThan:         ">",
		models.GreaterThanOrEquals: ">=",
		models.LessThan:            "<",
		models.LessThanOrEquals:    "<=",
		models.Like:                "LIKE",
		models.In:                  "IN",
		models.Contains:            "CONTAINS",
		models.Between:             "BETWEEN",
		models.Is:                  "IS",
	}

	if result, ok := operatorMap[op]; ok {
		return result
	}

	return string(op)
}
