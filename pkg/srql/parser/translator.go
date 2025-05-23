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
	if query == nil {
		return "", errCannotTranslateNilQuery
	}

	switch t.DBType {
	case ClickHouse:
		return t.toSQL(query, t.buildClickHouseWhere, errCannotTranslateNilQueryClickHouse, false)
	case Proton:
		return t.toSQL(query, t.buildProtonWhere, errCannotTranslateNilQueryProton, true)
	case ArangoDB:
		return t.toArangoDB(query)
	default:
		return "", fmt.Errorf("%w for database type: %s", errUnsupportedDatabaseType, t.DBType)
	}
}

const (
	defaultAscending      = "ASC"
	defaultDescending     = "DESC"
	defaultModelsBetween  = 2
	defaultBoolValueTrue  = "true"
	defaultBoolValueFalse = "false"
)

// toSQL is a generic SQL builder for Proton and ClickHouse. The unused bool is 'isStream' for Proton.
func (*Translator) toSQL(
	query *models.Query,
	whereBuilder func([]models.Condition) string, nilQueryError error, isStream bool) (string, error) {
	if query == nil {
		return "", nilQueryError
	}

	var sql strings.Builder

	switch query.Type {
	case models.Show, models.Find:
		sql.WriteString("SELECT * FROM ")
	case models.Count:
		sql.WriteString("SELECT COUNT(*) FROM ")
	}

	tableName := "" // Initialize tableName here
	switch query.Entity {
	case models.Devices:
		tableName = "devices"
	case models.Flows:
		tableName = "netflow_metrics"
	case models.Interfaces: // Added
		tableName = "discovered_interfaces"
	case models.Traps:
		tableName = "traps" // TODO: create
	case models.Connections:
		tableName = "connections" // TODO: missing? create
	case models.Logs:
		tableName = "logs" // TODO: also missing..
	default:
		tableName = strings.ToLower(string(query.Entity)) // Fallback for undefined entities
	}

	if isStream {
		tableName = fmt.Sprintf("table(%s)", tableName)
	}

	sql.WriteString(tableName)

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(whereBuilder(query.Conditions))
	}

	if len(query.OrderBy) > 0 {
		sql.WriteString(" ORDER BY ")

		var orderByParts []string

		for _, item := range query.OrderBy {
			direction := defaultAscending

			if item.Direction == models.Descending {
				direction = defaultDescending
			}

			orderByParts = append(orderByParts, fmt.Sprintf("%s %s", strings.ToLower(item.Field), direction))
		}

		sql.WriteString(strings.Join(orderByParts, ", "))
	}

	if query.HasLimit {
		sql.WriteString(fmt.Sprintf(" LIMIT %d", query.Limit))
	}

	return sql.String(), nil
}

// conditionFormatter defines a function to format a condition for a specific operator.
type conditionFormatter func(fieldName string, value interface{}) string
type conditionFormatterMulti func(fieldName string, values []interface{}) string

// conditionFormatters holds the mapping of operators to their formatters.
type conditionFormatters struct {
	comparison func(fieldName string, op models.OperatorType, value interface{}) string
	like       conditionFormatter
	contains   conditionFormatter
	in         conditionFormatterMulti
	between    conditionFormatterMulti
	is         conditionFormatter
}

// formatCondition is a generic condition formatter for SQL databases.
func (t *Translator) formatCondition(cond *models.Condition, formatters conditionFormatters) string {
	fieldName := strings.ToLower(cond.Field)

	switch {
	case t.isComparisonOperator(cond.Operator):
		return formatters.comparison(fieldName, cond.Operator, cond.Value)
	case cond.Operator == models.Like:
		return formatters.like(fieldName, cond.Value)
	case cond.Operator == models.Contains:
		return formatters.contains(fieldName, cond.Value)
	case cond.Operator == models.In:
		return formatters.in(fieldName, cond.Values)
	case cond.Operator == models.Between:
		return formatters.between(fieldName, cond.Values)
	case cond.Operator == models.Is:
		return formatters.is(fieldName, cond.Value)
	default:
		return ""
	}
}

// buildProtonWhere builds a WHERE clause for Proton SQL.
func (t *Translator) buildProtonWhere(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		func(cond *models.Condition) string {
			return t.formatCondition(cond, conditionFormatters{
				comparison: t.formatComparisonCondition,
				like:       t.formatProtonLikeCondition,
				contains:   t.formatProtonContainsCondition,
				in:         t.formatProtonInCondition,
				between:    t.formatProtonBetweenCondition,
				is:         t.formatProtonIsCondition,
			})
		},
		t.buildProtonWhere,
	)
}

// buildClickHouseWhere builds a WHERE clause for ClickHouse SQL.
func (t *Translator) buildClickHouseWhere(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		func(cond *models.Condition) string {
			return t.formatCondition(cond, conditionFormatters{
				comparison: t.formatComparisonCondition,
				like:       t.formatLikeCondition,
				contains:   t.formatContainsCondition,
				in:         t.formatInCondition,
				between:    t.formatBetweenCondition,
				is:         t.formatIsCondition,
			})
		},
		t.buildClickHouseWhere,
	)
}

// isComparisonOperator checks if the operator is a basic comparison operator.
func (*Translator) isComparisonOperator(op models.OperatorType) bool {
	return op == models.Equals || op == models.NotEquals ||
		op == models.GreaterThan || op == models.GreaterThanOrEquals ||
		op == models.LessThan || op == models.LessThanOrEquals
}

// formatComparisonCondition formats a basic comparison condition.
func (t *Translator) formatComparisonCondition(fieldName string, op models.OperatorType, value interface{}) string {
	return fmt.Sprintf("%s %s %s", fieldName, op, t.formatClickHouseValue(value)) // Reuse ClickHouse value formatter for both
}

// formatProtonLikeCondition formats a LIKE condition.
func (t *Translator) formatProtonLikeCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("%s LIKE %s", fieldName, t.formatProtonValue(value))
}

// formatProtonContainsCondition formats a CONTAINS condition.
func (t *Translator) formatProtonContainsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("position(%s, %s) > 0", fieldName, t.formatProtonValue(value))
}

// formatProtonInCondition formats an IN condition.
func (t *Translator) formatProtonInCondition(fieldName string, values []interface{}) string {
	formattedValues := make([]string, 0, len(values))

	for _, val := range values {
		formattedValues = append(formattedValues, t.formatProtonValue(val))
	}

	return fmt.Sprintf("%s IN (%s)", fieldName, strings.Join(formattedValues, ", "))
}

// formatProtonBetweenCondition formats a BETWEEN condition.
func (t *Translator) formatProtonBetweenCondition(fieldName string, values []interface{}) string {
	if len(values) == defaultModelsBetween {
		return fmt.Sprintf("%s BETWEEN %s AND %s",
			fieldName,
			t.formatProtonValue(values[0]),
			t.formatProtonValue(values[1]))
	}

	return ""
}

// formatProtonIsCondition formats an IS NULL or IS NOT NULL condition.
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
		countAQL := fmt.Sprintf("RETURN LENGTH(\n%s\n)", aql.String())
		return countAQL, nil
	}

	return aql.String(), nil
}

// buildConditionString is a generic method to build condition strings for different databases.
func (*Translator) buildConditionString(
	conditions []models.Condition,
	formatCondition func(*models.Condition) string,
	recursiveBuild func([]models.Condition) string) string {
	if len(conditions) == 0 {
		return ""
	}

	var builder strings.Builder

	for i, cond := range conditions {
		if i > 0 {
			builder.WriteString(fmt.Sprintf(" %s ", cond.LogicalOp))
		}

		if cond.IsComplex {
			builder.WriteString("(")
			builder.WriteString(recursiveBuild(cond.Complex))
			builder.WriteString(")")

			continue
		}

		builder.WriteString(formatCondition(&cond))
	}

	return builder.String()
}

// buildArangoDBFilter builds a FILTER clause for ArangoDB AQL.
func (t *Translator) buildArangoDBFilter(conditions []models.Condition) string {
	return t.buildConditionString(
		conditions,
		t.formatArangoDBCondition,
		t.buildArangoDBFilter,
	)
}

// formatArangoDBCondition formats a single condition for ArangoDB AQL.
func (t *Translator) formatArangoDBCondition(cond *models.Condition) string {
	fieldName := strings.ToLower(cond.Field)

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

// formatArangoDBEqualsCondition formats an equals condition.
func (t *Translator) formatArangoDBEqualsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("doc.%s == %s", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBNotEqualsCondition formats a not equals condition.
func (t *Translator) formatArangoDBNotEqualsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("doc.%s != %s", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBComparisonCondition formats a comparison condition (>, >=, <, <=).
func (t *Translator) formatArangoDBComparisonCondition(fieldName string, op models.OperatorType, value interface{}) string {
	return fmt.Sprintf("doc.%s %s %s", fieldName, t.translateOperator(op), t.formatArangoDBValue(value))
}

// formatArangoDBLikeCondition formats a LIKE condition.
func (t *Translator) formatArangoDBLikeCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("LIKE(doc.%s, %s, true)", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBContainsCondition formats a CONTAINS condition.
func (t *Translator) formatArangoDBContainsCondition(fieldName string, value interface{}) string {
	return fmt.Sprintf("CONTAINS(doc.%s, %s)", fieldName, t.formatArangoDBValue(value))
}

// formatArangoDBInCondition formats an IN condition.
func (t *Translator) formatArangoDBInCondition(fieldName string, values []interface{}) string {
	formattedValues := make([]string, 0, len(values))

	for _, val := range values {
		formattedValues = append(formattedValues, t.formatArangoDBValue(val))
	}

	return fmt.Sprintf("doc.%s IN [%s]", fieldName, strings.Join(formattedValues, ", "))
}

// formatArangoDBBetweenCondition formats a BETWEEN condition.
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

// formatArangoDBIsCondition formats an IS NULL or IS NOT NULL condition.
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

// formatClickHouseValue formats a value for ClickHouse SQL
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

// formatArangoDBValue formats a value for ArangoDB AQL
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

// translateOperator maps operator types to their string representations
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
