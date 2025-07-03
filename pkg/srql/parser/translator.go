package parser

import (
	"fmt"
	"log"
	"strings"
	"time"

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

// applyDefaultFilters adds implicit conditions for certain entities when the
// user query omits them. Currently this ensures `sweep_results` only returns
// records with `discovery_source = 'sweep'` unless another discovery_source
// condition is specified.
func (*Translator) applyDefaultFilters(q *models.Query) {
	if q == nil {
		return
	}

	// Apply default filters for entities that need them
	if q.Entity == models.SweepResults {
		applySweepResultsDefaultFilter(q)
	}

	// SNMP entities need metric_type filtering since they use timeseries_metrics table
	if q.Entity == models.SNMPResults || q.Entity == models.SNMPMetrics {
		applySNMPDefaultFilter(q)
	}
}

// applySweepResultsDefaultFilter adds the default discovery_source filter for SweepResults
func applySweepResultsDefaultFilter(q *models.Query) {
	if !hasDiscoverySourceCondition(q.Conditions) {
		cond := models.Condition{
			Field:    "discovery_source",
			Operator: models.Equals,
			Value:    "sweep",
		}

		if len(q.Conditions) > 0 {
			cond.LogicalOp = models.And
		}

		q.Conditions = append(q.Conditions, cond)
	}
}

// applySNMPDefaultFilter adds the default metric_type filter for SNMP entities
func applySNMPDefaultFilter(q *models.Query) {
	if !hasMetricTypeCondition(q.Conditions) {
		cond := models.Condition{
			Field:    "metric_type",
			Operator: models.Equals,
			Value:    "snmp",
		}

		if len(q.Conditions) > 0 {
			cond.LogicalOp = models.And
		}

		q.Conditions = append(q.Conditions, cond)
	}
}

// hasDiscoverySourceCondition checks if a condition on discovery_source already
// exists in the provided slice. Nested conditions are not inspected to keep the
// check simple.
func hasDiscoverySourceCondition(conds []models.Condition) bool {
	for _, c := range conds {
		if strings.EqualFold(c.Field, "discovery_source") {
			return true
		}
	}

	return false
}

// hasMetricTypeCondition checks if a condition on metric_type already
// exists in the provided slice. Nested conditions are not inspected to keep the
// check simple.
func hasMetricTypeCondition(conds []models.Condition) bool {
	for _, c := range conds {
		if strings.EqualFold(c.Field, "metric_type") {
			return true
		}
	}

	return false
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

	// Apply any implicit filters based on the entity type
	t.applyDefaultFilters(query)

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

// getEntityPrimaryKeyMapData returns a map of entity types to their primary keys and whether they need ROW_NUMBER()
func getEntityPrimaryKeyMapData() map[models.EntityType]struct {
	key         string
	needsRowNum bool
} {
	return map[models.EntityType]struct {
		key         string
		needsRowNum bool
	}{
		// For interfaces, a composite key of device_ip and ifIndex is typically used for uniqueness
		models.Interfaces: {"device_ip, ifIndex", true},
		// Devices is a versioned_kv stream, naturally providing latest
		models.Devices: {"", false},
		// Assuming flow_id is the primary key for flows
		models.Flows: {"flow_id", true},
		// Assuming trap_id or similar is the primary key for traps
		models.Traps: {"", false},
		// Assuming connection_id or similar is the primary key for connections
		models.Connections: {"", false},
		// Assuming log_id or similar is the primary key for logs
		models.Logs: {"", false},
		// Services stream is versioned_kv, latest handled automatically
		models.Services:      {"", false},
		models.SweepResults:  {"", false}, // SweepResults is a versioned_kv stream
		models.ICMPResults:   {"", false}, // ICMPResults is a versioned_kv stream
		models.SNMPResults:   {"", false}, // SNMPResults is a versioned_kv stream
		models.Events:        {"", false}, // Events stream is append-only
		models.Pollers:       {"poller_id", true},
		models.CPUMetrics:    {"device_id, core_id", true},
		models.DiskMetrics:   {"device_id, mount_point", true},
		models.MemoryMetrics: {"device_id", true},
	}
}

// getEntityPrimaryKey returns the assumed primary key for an entity, used for LATEST queries.
// This is used for non-versioned_kv streams that need ROW_NUMBER()
func (*Translator) getEntityPrimaryKey(entity models.EntityType) (string, bool) {
	entityPrimaryKeyMap := getEntityPrimaryKeyMapData()
	if info, exists := entityPrimaryKeyMap[entity]; exists {
		return info.key, info.needsRowNum
	}

	return "", false // Indicate LATEST is not supported for this entity or it's versioned_kv
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
		fmt.Fprintf(&sql, " LIMIT %d", query.Limit)
	}

	return sql.String(), nil
}

// getEntityToTableMapData returns a map of entity types to their base table names
func getEntityToTableMapData() map[models.EntityType]string {
	return map[models.EntityType]string{
		models.Devices:       "unified_devices", // Materialized view approach uses unified_devices stream
		models.Flows:         "netflow_metrics",
		models.Interfaces:    "discovered_interfaces",
		models.Traps:         "traps",
		models.Connections:   "connections",
		models.Logs:          "logs",
		models.Services:      "services",
		models.SweepResults:  "sweep_results",
		models.ICMPResults:   "icmp_results",
		models.SNMPResults:   "timeseries_metrics",
		models.Events:        "events",
		models.Pollers:       "pollers",
		models.CPUMetrics:    "cpu_metrics",
		models.DiskMetrics:   "disk_metrics",
		models.MemoryMetrics: "memory_metrics",
		models.SNMPMetrics:   "timeseries_metrics",
	}
}

// getProtonBaseTableName returns the base table name for a given entity type
func (*Translator) getProtonBaseTableName(entity models.EntityType) string {
	entityToTableMap := getEntityToTableMapData()
	if tableName, exists := entityToTableMap[entity]; exists {
		return tableName
	}

	return strings.ToLower(string(entity)) // Fallback
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
	fmt.Fprintf(sql, "WITH filtered_data AS (\n  SELECT * FROM table(%s)", baseTableName)

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildProtonWhere(query.Conditions))
	}

	sql.WriteString("\n),\n")

	fmt.Fprintf(sql,
		"latest_records AS (\n  SELECT *, ROW_NUMBER() OVER (PARTITION BY %s "+
			"ORDER BY _tp_time DESC) AS rn\n  FROM filtered_data\n)\n", primaryKey)

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
		fmt.Fprintf(sql, " LIMIT %d", query.Limit)
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

const (
	defaultToday     = "TODAY"
	defaultYesterday = "YESTERDAY"
)

// formatDateCondition handles date(field) = TODAY/YESTERDAY specifically
func (t *Translator) formatDateCondition(_, translatedFieldName string, value interface{}) (string, bool) {
	sVal, ok := value.(string)
	if !ok {
		return "", false
	}

	upperVal := strings.ToUpper(sVal)
	if upperVal != defaultToday && upperVal != defaultYesterday {
		return "", false
	}

	switch t.DBType {
	case Proton, ClickHouse:
		return t.formatProtonOrClickHouseDateCondition(translatedFieldName, upperVal), true
	case ArangoDB:
		return t.formatArangoDBDateCondition(translatedFieldName, upperVal), true
	default:
		return "", false
	}
}

// formatProtonOrClickHouseDateCondition formats date conditions for Proton or ClickHouse
func (*Translator) formatProtonOrClickHouseDateCondition(fieldName, dateValue string) string {
	if dateValue == defaultToday {
		return fmt.Sprintf("%s = today()", fieldName)
	}

	// Must be YESTERDAY based on validation in formatDateCondition
	return fmt.Sprintf("%s = yesterday()", fieldName)
}

// formatArangoDBDateCondition formats date conditions for ArangoDB
func (*Translator) formatArangoDBDateCondition(fieldName, dateValue string) string {
	now := time.Now() // Consider passing time via context for testability

	if dateValue == defaultToday {
		todayDateStr := now.Format("2006-01-02")
		return fmt.Sprintf("%s = '%s'", fieldName, todayDateStr)
	}

	// Must be YESTERDAY based on validation in formatDateCondition
	yesterdayDateStr := now.AddDate(0, 0, -1).Format("2006-01-02")

	return fmt.Sprintf("%s = '%s'", fieldName, yesterdayDateStr)
}

// formatOperatorCondition formats a condition based on its operator
func (t *Translator) formatOperatorCondition(fieldName string, cond *models.Condition, formatters conditionFormatters) string {
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

// formatCondition is a generic condition formatter for SQL databases.
func (t *Translator) formatCondition(cond *models.Condition, formatters conditionFormatters) string {
	rawFieldName := cond.Field // Can be "field" or "func(field)"
	operator := cond.Operator
	rawValue := cond.Value

	// Handle date(field) = TODAY/YESTERDAY specifically
	if lowerRawFieldName := strings.ToLower(rawFieldName); strings.HasPrefix(lowerRawFieldName, "date(") &&
		operator == models.Equals {
		translatedFieldName := t.translateFieldName(rawFieldName, t.DBType == ArangoDB) // pass Arango context
		if result, handled := t.formatDateCondition(rawFieldName, translatedFieldName, rawValue); handled {
			return result
		}
	}

	// Fallback to existing generic formatters
	fieldName := t.translateFieldName(rawFieldName, t.DBType == ArangoDB && !strings.Contains(rawFieldName, "("))

	return t.formatOperatorCondition(fieldName, cond, formatters)
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
	lowerField := strings.ToLower(fieldName)

	if lowerField == "discovery_sources" {
		formatted := t.formatGenericValue(value, t.DBType)

		switch t.DBType {
		case Proton, ClickHouse:
			if op == models.Equals {
				// discovery_sources is stored as JSON string, so use string search
				// We need to construct a pattern that searches for: "source":"netbox"
				// Extract the raw value without quotes and wrap it in double quotes for JSON
				rawValue := strings.Trim(formatted, "'\"")
				pattern := fmt.Sprintf("'%%\"source\":\"%s\"%%'", rawValue)
				return "discovery_sources LIKE " + pattern
			}

			if op == models.NotEquals {
				// discovery_sources is stored as JSON string, so use string search
				rawValue := strings.Trim(formatted, "'\"")
				pattern := fmt.Sprintf("'%%\"source\":\"%s\"%%'", rawValue)
				return "discovery_sources NOT LIKE " + pattern
			}
		case ArangoDB:
			if op == models.Equals {
				return fmt.Sprintf("CONTAINS(doc.discovery_sources, %s)", formatted)
			}

			if op == models.NotEquals {
				return fmt.Sprintf("NOT CONTAINS(doc.discovery_sources, %s)", formatted)
			}
		}
	}

	// fieldName is now pre-translated if it was a function like to_date(timestamp)
	// or doc.field for Arango.
	// Value is the original value from the query (e.g. "some_string", 123)
	// It does NOT include "TODAY" or "YESTERDAY" here if handled above.
	return fmt.Sprintf("%s %s %s", fieldName, op, t.formatGenericValue(value, t.DBType))
}

func (t *Translator) formatGenericValue(value interface{}, dbType DatabaseType) string {
	// This function should handle basic types correctly for each DB.
	// It should NOT re-interpret "TODAY" or "YESTERDAY" as they are handled earlier.
	switch dbType {
	case Proton:
		return t.formatProtonValue(value)
	case ClickHouse:
		return t.formatClickHouseValue(value)
	case ArangoDB:
		return t.formatArangoDBValue(value)
	default:
		return fmt.Sprintf("%v", value) // Basic fallback
	}
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
// It specifically handles the translation of SRQL `date(field) = 'value'` (where value can be TODAY, YESTERDAY, or a date string)
// into the correct AQL `SUBSTRING(doc.field, 0, 10) = 'YYYY-MM-DD'`.
// For other operators or fields not matching this pattern, it delegates to other specific helper functions.
func (t *Translator) formatArangoDBCondition(cond *models.Condition) string {
	// srqlFieldName is the raw field identifier from the SRQL query, lowercased.
	// Examples: "status", "ip", "date(timestamp)", "some_other_function(field)"
	srqlFieldName := strings.ToLower(cond.Field)

	// Special handling for: date(any_field) = 'date_string_or_keyword'
	// This is the primary fix for the failing ArangoDB test cases.
	if strings.HasPrefix(srqlFieldName, "date(") &&
		strings.HasSuffix(srqlFieldName, ")") &&
		cond.Operator == models.Equals {
		// Extract the actual field name from inside "date(...)"
		// e.g., "date(timestamp)" becomes "timestamp"
		innerField := strings.TrimSuffix(strings.TrimPrefix(srqlFieldName, "date("), ")")

		// Construct the ArangoDB Left Hand Side (LHS) for date comparison using SUBSTRING.
		// e.g., "SUBSTRING(doc.timestamp, 0, 10)"
		arangoLHS := fmt.Sprintf("SUBSTRING(doc.%s, 0, 10)", innerField)

		// The value (cond.Value) from SRQL should be a string: "TODAY", "YESTERDAY", or a literal date "YYYY-MM-DD".
		dateValueString, ok := cond.Value.(string)
		if !ok {
			log.Println("Warning: Expected string value for date condition, got:", cond.Value)
		} else {
			// Handle SRQL keywords TODAY, YESTERDAY, or a literal date string.
			now := time.Now() // For testability, this could be injected (e.g., via Translator or context).
			todayDateStr := now.Format("2006-01-02")
			yesterdayDateStr := now.AddDate(0, 0, -1).Format("2006-01-02")

			switch strings.ToUpper(dateValueString) {
			case defaultToday:
				return fmt.Sprintf("%s == '%s'", arangoLHS, todayDateStr)
			case defaultYesterday:
				return fmt.Sprintf("%s == '%s'", arangoLHS, yesterdayDateStr)
			default:
				// Assumes dateValueString is a literal date like "2023-10-20".
				// t.formatArangoDBValue will handle quoting if it's a string.
				return fmt.Sprintf("%s == %s", arangoLHS, t.formatArangoDBValue(dateValueString))
			}
		}
	}

	// Fallback for all other conditions:
	// - Conditions not matching the "date(...) = 'string_value'" pattern.
	// - Conditions using operators other than models.Equals.
	// These will use the existing helper functions. These helpers typically expect
	// the srqlFieldName and prepend "doc." to it. If srqlFieldName is "date(timestamp)",
	// they might produce "doc.date(timestamp)" which is not the SUBSTRING version.
	// This part of the code remains consistent with the behavior *before* this specific fix,
	// meaning other function translations or uses with other operators might still need refinement
	// in those respective helper functions.
	switch cond.Operator {
	case models.Equals:
		// This case is reached if the specific date equality logic above was not triggered.
		// e.g., field is not date(), operator is not equals, or value was not a string for date().
		return t.formatArangoDBEqualsCondition(srqlFieldName, cond.Value)
	case models.NotEquals:
		return t.formatArangoDBNotEqualsCondition(srqlFieldName, cond.Value)
	case models.GreaterThan, models.GreaterThanOrEquals, models.LessThan, models.LessThanOrEquals:
		return t.formatArangoDBComparisonCondition(srqlFieldName, cond.Operator, cond.Value)
	case models.Like:
		return t.formatArangoDBLikeCondition(srqlFieldName, cond.Value)
	case models.Contains:
		return t.formatArangoDBContainsCondition(srqlFieldName, cond.Value)
	case models.In:
		return t.formatArangoDBInCondition(srqlFieldName, cond.Values)
	case models.Between:
		return t.formatArangoDBBetweenCondition(srqlFieldName, cond.Values)
	case models.Is:
		return t.formatArangoDBIsCondition(srqlFieldName, cond.Value)
	default:
		// Fallback for any unhandled operator.
		// Consider logging an error or returning a specific error value.
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

func (t *Translator) translateFieldName(fieldName string, forArangoDoc bool) string {
	lowerFieldName := strings.ToLower(fieldName)

	if strings.HasPrefix(lowerFieldName, "date(") && strings.HasSuffix(lowerFieldName, ")") {
		// Extract actual field name from "date(actual_field)"
		innerField := strings.TrimSuffix(strings.TrimPrefix(lowerFieldName, "date("), ")")

		if t.DBType == Proton {
			return fmt.Sprintf("to_date(%s)", innerField)
		}

		if t.DBType == ClickHouse {
			return fmt.Sprintf("toDate(%s)", innerField) // Use toDate for ClickHouse
		}

		if t.DBType == ArangoDB {
			// For ArangoDB, if timestamp is stored as ISO8601 string.
			// This extracts 'YYYY-MM-DD' part.
			// AQL's DATE_TRUNC might be better if available and applicable.
			if forArangoDoc {
				return fmt.Sprintf("SUBSTRING(doc.%s, 0, 10)", innerField)
			}

			return fmt.Sprintf("SUBSTRING(%s, 0, 10)", innerField) // For general use if not in doc context
		}
	}

	// Default field handling (lowercase and prefix for ArangoDB)
	if t.DBType == ArangoDB && forArangoDoc && !strings.Contains(lowerFieldName, ".") { // simple field for arango
		return fmt.Sprintf("doc.%s", lowerFieldName)
	}

	return lowerFieldName
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
