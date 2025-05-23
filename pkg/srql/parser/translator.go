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
	case Proton:
		return t.buildProtonQuery(query)
	case ClickHouse:
		return t.buildClickHouseQuery(query)
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

// getEntityPrimaryKey returns the assumed primary key for an entity, used for LATEST queries.
// This is used for non-versioned_kv streams that need ROW_NUMBER()
func (*Translator) getEntityPrimaryKey(entity models.EntityType) (string, bool) {
	switch entity {
	case models.Interfaces:
		// For interfaces, a composite key of device_ip and ifIndex is typically used for uniqueness
		return "device_ip, ifIndex", true
	case models.Devices:
		// Devices is a versioned_kv stream, naturally providing latest
		return "", false
	case models.Flows:
		// Assuming flow_id is the primary key for flows
		return "flow_id", true
	case models.Traps:
		// Assuming trap_id or similar is the primary key for traps
		return "", false
	case models.Connections:
		// Assuming connection_id or similar is the primary key for connections
		return "", false
	case models.Logs:
		// Assuming log_id or similar is the primary key for logs
		return "", false
	case models.SweepResults:
		// SweepResults is a versioned_kv stream
		return "", false
	case models.ICMPResults:
		// ICMPResults is a versioned_kv stream
		return "", false
	case models.SNMPResults:
		// SNMPResults is a versioned_kv stream
		return "", false
	default:
		return "", false // Indicate LATEST is not supported for this entity or it's versioned_kv
	}
}

// buildClickHouseQuery builds a SQL query for ClickHouse.
func (t *Translator) buildClickHouseQuery(query *models.Query) (string, error) {
	if query == nil {
		return "", errCannotTranslateNilQueryClickHouse
	}

	var sql strings.Builder

	// Note: LATEST is not applied to ClickHouse here.
	switch query.Type {
	case models.Show, models.Find:
		sql.WriteString("SELECT * FROM ")
	case models.Count:
		sql.WriteString("SELECT COUNT(*) FROM ")
	}

	sql.WriteString(strings.ToLower(string(query.Entity)))

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildClickHouseWhere(query.Conditions))
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

// getProtonBaseTableName returns the base table name for a given entity type
func (*Translator) getProtonBaseTableName(entity models.EntityType) string {
	switch entity {
	case models.Devices:
		return "devices"
	case models.Flows:
		return "netflow_metrics"
	case models.Interfaces:
		return "discovered_interfaces"
	case models.Traps:
		return "traps"
	case models.Connections:
		return "connections"
	case models.Logs:
		return "logs"
	case models.SweepResults:
		return "sweep_results"
	case models.ICMPResults:
		return "icmp_results"
	case models.SNMPResults:
		return "snmp_results"
	default:
		return strings.ToLower(string(entity)) // Fallback
	}
}

// validateLatestQuery checks if the LATEST query is valid for the given entity and query type
func (t *Translator) validateLatestQuery(
	entity models.EntityType, queryType models.QueryType) (primaryKey string, isValid bool, err error) {
	// For non-versioned_kv streams (like 'discovered_interfaces'), use ROW_NUMBER()
	primaryKey, ok := t.getEntityPrimaryKey(entity)
	if !ok {
		return "", false, fmt.Errorf("latest keyword not supported for entity '%s' "+
			"without a defined primary key for Proton using ROW_NUMBER() method", entity)
	}

	if queryType == models.Count {
		return "", false, fmt.Errorf("count with LATEST is not supported for " +
			"non-versioned streams; consider 'SELECT count() FROM (SHOW <entity> LATEST)' in client side")
	}

	return primaryKey, true, nil
}

// buildLatestCTE constructs a Common Table Expression (CTE) for getting the latest records
func (t *Translator) buildLatestCTE(sql *strings.Builder, query *models.Query, baseTableName, primaryKey string) {
	// Construct the CTE with ROW_NUMBER()
	// IMPORTANT: Added table() wrapper around baseTableName here
	sql.WriteString(fmt.Sprintf("WITH filtered_data AS (\n  SELECT * FROM table(%s)", baseTableName))

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildProtonWhere(query.Conditions))
	}

	sql.WriteString("\n),\n")

	sql.WriteString(fmt.Sprintf("latest_records AS (\n  SELECT *, ROW_NUMBER() OVER (PARTITION BY %s ORDER BY _tp_time DESC) AS rn\n  FROM filtered_data\n)\n", primaryKey))

	sql.WriteString("SELECT * EXCEPT rn FROM latest_records WHERE rn = 1")
}

// buildLatestProtonQuery builds a SQL query for Timeplus Proton with LATEST logic
func (t *Translator) buildLatestProtonQuery(sql *strings.Builder, query *models.Query, baseTableName string) (string, error) {
	// Handle 'devices' separately as it's a versioned_kv stream, naturally providing latest
	if query.Entity == models.Devices {
		t.buildStandardProtonQuery(sql, query, baseTableName)
		return sql.String(), nil
	}

	// Validate the query for LATEST support
	primaryKey, valid, err := t.validateLatestQuery(query.Entity, query.Type)
	if !valid {
		return "", err
	}

	// Build the CTE for latest records
	t.buildLatestCTE(sql, query, baseTableName, primaryKey)

	// As discussed, ORDER BY or LIMIT are implicitly ignored here for non-versioned streams with LATEST
	// due to the streaming aggregation limitations.
	return sql.String(), nil
}

// buildProtonQuery builds a SQL query for Timeplus Proton, handling LATEST logic.
func (t *Translator) buildProtonQuery(query *models.Query) (string, error) {
	if query == nil {
		return "", errCannotTranslateNilQueryProton
	}

	var sql strings.Builder

	baseTableName := t.getProtonBaseTableName(query.Entity)

	if query.IsLatest {
		return t.buildLatestProtonQuery(&sql, query, baseTableName)
	}

	// Non-LATEST Proton queries: return all historical records
	t.buildStandardProtonQuery(&sql, query, baseTableName)

	return sql.String(), nil
}

// buildStandardProtonQuery builds a standard Proton query with SELECT, FROM, WHERE, ORDER BY, and LIMIT clauses.
// This helper function eliminates code duplication between different query paths.
func (t *Translator) buildStandardProtonQuery(sql *strings.Builder, query *models.Query, baseTableName string) {
	switch query.Type {
	case models.Show, models.Find:
		sql.WriteString("SELECT * FROM table(") // Added table() here
	case models.Count:
		sql.WriteString("SELECT COUNT(*) FROM table(") // Added table() here
	}

	sql.WriteString(baseTableName)
	sql.WriteString(")") // Closing table()

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildProtonWhere(query.Conditions))
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
