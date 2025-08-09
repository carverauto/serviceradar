package parser

import (
	"fmt"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/srql/models"
)

// DatabaseType defines the type of database we're translating to
type DatabaseType string

const (
	ClickHouse DatabaseType = "clickhouse"
	Proton     DatabaseType = "proton"
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
	if q.Entity == models.DeviceUpdates {
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
			Field:    "discovery_sources",
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
		if strings.EqualFold(c.Field, "discovery_source") || strings.EqualFold(c.Field, "discovery_sources") {
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

// TransformQuery transforms unsupported entity types to their equivalent supported types
func (t *Translator) TransformQuery(query *models.Query) {
	if query.Entity == models.SweepResults {
		// Transform sweep_results to devices query with sweep filter
		query.Entity = models.Devices

		// Add sweep discovery source filter if not already present
		if !t.hasDiscoverySourcesCondition(query.Conditions) {
			sweepCondition := models.Condition{
				Field:    "discovery_sources",
				Operator: models.Equals,
				Value:    "sweep",
			}

			// Add logical operator if there are existing conditions
			if len(query.Conditions) > 0 {
				sweepCondition.LogicalOp = models.And
			}

			query.Conditions = append(query.Conditions, sweepCondition)
		}
	}
}

// hasDiscoverySourcesCondition checks if discovery_sources condition already exists
func (*Translator) hasDiscoverySourcesCondition(conditions []models.Condition) bool {
	for _, condition := range conditions {
		if condition.Field == "discovery_sources" || condition.Field == "discovery_source" {
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

	// Transform unsupported entity types to their equivalent supported types
	t.TransformQuery(query)

	// Convert time clauses to WHERE conditions
	t.convertTimeClauseToCondition(query)

	// Apply any implicit filters based on the entity type
	t.applyDefaultFilters(query)

	switch t.DBType {
	case Proton:
		return t.buildProtonQuery(query)
	case ClickHouse:
		return t.buildClickHouseQuery(query)
	default:
		return "", fmt.Errorf("%w for database type: %s", errUnsupportedDatabaseType, t.DBType)
	}
}

// TranslateForStreaming converts a Query model to a streaming database query string (without table() wrapper)
func (t *Translator) TranslateForStreaming(query *models.Query) (string, error) {
	if query == nil {
		return "", errCannotTranslateNilQuery
	}

	// Transform unsupported entity types to their equivalent supported types
	t.TransformQuery(query)

	// Convert time clauses to WHERE conditions
	t.convertTimeClauseToCondition(query)

	// Apply any implicit filters based on the entity type
	t.applyDefaultFilters(query)

	switch t.DBType {
	case Proton:
		return t.buildProtonStreamingQuery(query)
	case ClickHouse:
		return t.buildClickHouseStreamingQuery(query)
	default:
		return "", fmt.Errorf("%w for database type: %s", errUnsupportedDatabaseType, t.DBType)
	}
}

const (
	defaultAscending      = "ASC"
	defaultDescending     = "DESC"
	defaultModelsBetween  = 2
	defaultBoolValueTrue  = "1"
	defaultBoolValueFalse = "0"
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
		models.Services:       {"", false},
		models.SweepResults:   {"", false}, // SweepResults uses unified_devices which is versioned_kv
		models.DeviceUpdates:  {"", false}, // DeviceUpdates is a versioned_kv stream
		models.ICMPResults:    {"", false}, // ICMPResults is a versioned_kv stream
		models.SNMPResults:    {"", false}, // SNMPResults is a versioned_kv stream
		models.Events:         {"", false}, // Events stream is append-only
		models.Pollers:        {"poller_id", true},
		models.CPUMetrics:     {"device_id, core_id", true},
		models.DiskMetrics:    {"device_id, mount_point", true},
		models.MemoryMetrics:  {"device_id", true},
		models.ProcessMetrics: {"device_id, pid", true},
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
		if query.Function != "" {
			// Handle function calls like DISTINCT(field)
			sql.WriteString("SELECT ")
			sql.WriteString(t.buildFunctionCall(query))
			sql.WriteString(" FROM ")
		} else {
			sql.WriteString("SELECT * FROM ")
		}
	case models.Count:
		sql.WriteString("SELECT count() FROM ")
	case models.Stream:
		return t.buildClickHouseStreamQuery(query)
	}

	sql.WriteString(strings.ToLower(string(query.Entity)))

	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildClickHouseWhere(query.Conditions, query.Entity))
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

// buildClickHouseStreamQuery builds a STREAM query for ClickHouse
func (t *Translator) buildClickHouseStreamQuery(query *models.Query) (string, error) {
	var sql strings.Builder

	// Build SELECT clause with specified fields
	sql.WriteString("SELECT ")

	if len(query.SelectFields) > 0 {
		sql.WriteString(strings.Join(query.SelectFields, ", "))
	} else {
		sql.WriteString("*")
	}

	sql.WriteString(" FROM ")
	sql.WriteString(strings.ToLower(string(query.Entity)))

	// Build WHERE clause
	if len(query.Conditions) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(t.buildClickHouseWhere(query.Conditions, query.Entity))
	}

	// Build GROUP BY clause
	if len(query.GroupBy) > 0 {
		sql.WriteString(" GROUP BY ")
		sql.WriteString(strings.Join(query.GroupBy, ", "))
	}

	// Build ORDER BY clause
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

	// Build LIMIT clause
	if query.HasLimit {
		fmt.Fprintf(&sql, " LIMIT %d", query.Limit)
	}

	return sql.String(), nil
}

// entityConfig holds configuration for each entity type
type entityConfig struct {
	tableName      string
	timestampField string
}

// getEntityConfigurations returns a map of entity types to their configurations
func getEntityConfigurations() map[models.EntityType]entityConfig {
	return map[models.EntityType]entityConfig{
		models.Devices:            {tableName: "unified_devices", timestampField: "last_seen"},
		models.Flows:              {tableName: "netflow_metrics", timestampField: "timestamp"},
		models.Interfaces:         {tableName: "discovered_interfaces", timestampField: "last_seen"},
		models.SweepResults:       {tableName: "unified_devices", timestampField: "timestamp"},
		models.Traps:              {tableName: "traps", timestampField: "timestamp"},
		models.Connections:        {tableName: "connections", timestampField: "timestamp"},
		models.Logs:               {tableName: "logs", timestampField: "timestamp"},
		models.Services:           {tableName: "services", timestampField: "last_seen"},
		models.DeviceUpdates:      {tableName: "device_updates", timestampField: "timestamp"},
		models.ICMPResults:        {tableName: "icmp_results", timestampField: "timestamp"},
		models.SNMPResults:        {tableName: "timeseries_metrics", timestampField: "timestamp"},
		models.Events:             {tableName: "events", timestampField: "timestamp"},
		models.Pollers:            {tableName: "pollers", timestampField: "timestamp"},
		models.CPUMetrics:         {tableName: "cpu_metrics", timestampField: "timestamp"},
		models.DiskMetrics:        {tableName: "disk_metrics", timestampField: "timestamp"},
		models.MemoryMetrics:      {tableName: "memory_metrics", timestampField: "timestamp"},
		models.ProcessMetrics:     {tableName: "process_metrics", timestampField: "timestamp"},
		models.SNMPMetrics:        {tableName: "timeseries_metrics", timestampField: "timestamp"},
		models.OtelTraces:         {tableName: "otel_traces", timestampField: "timestamp"},
		models.OtelMetrics:        {tableName: "otel_metrics", timestampField: "timestamp"},
		models.OtelTraceSummaries: {tableName: "otel_trace_summaries_final", timestampField: "timestamp"},
		models.OtelSpansEnriched:  {tableName: "otel_spans_enriched", timestampField: "timestamp"},
		models.OtelRootSpans:      {tableName: "otel_root_spans", timestampField: "trace_id"},
	}
}

// getEntityToTableMapData returns a map of entity types to their base table names
func getEntityToTableMapData() map[models.EntityType]string {
	configs := getEntityConfigurations()
	result := make(map[models.EntityType]string, len(configs))

	for entity, config := range configs {
		result[entity] = config.tableName
	}

	return result
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
		sql.WriteString(t.buildProtonWhere(query.Conditions, query.Entity))
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
		if query.Function != "" {
			// Handle function calls like DISTINCT(field)
			sql.WriteString("SELECT ")
			sql.WriteString(t.buildFunctionCall(query))
			sql.WriteString(" FROM table(")
		} else {
			sql.WriteString("SELECT * FROM table(") // Added table() here
		}
	case models.Count:
		sql.WriteString("SELECT count() FROM table(") // Added table() here
	case models.Stream:
		t.buildStreamQuery(sql, query, baseTableName)
		return
	}

	sql.WriteString(baseTableName)
	sql.WriteString(")") // Closing table()

	// Build WHERE clause
	var whereClauses []string

	if len(query.Conditions) > 0 {
		conditionsStr := t.buildProtonWhere(query.Conditions, query.Entity)
		// Only wrap user conditions in parentheses if there will be additional system filters
		if query.Entity == models.Devices {
			whereClauses = append(whereClauses, fmt.Sprintf("(%s)", conditionsStr))
		} else {
			whereClauses = append(whereClauses, conditionsStr)
		}
	}

	// Add implicit filter for non-deleted devices, only for 'devices' entity.
	// This ensures queries like 'show devices' automatically exclude retracted devices.
	if query.Entity == models.Devices {
		deletedFilter := "coalesce(metadata['_deleted'], '') != 'true'"
		whereClauses = append(whereClauses, deletedFilter)
	}

	if len(whereClauses) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(strings.Join(whereClauses, " AND "))
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

// buildStreamQuery builds a STREAM query for Proton that supports GROUP BY aggregations
func (t *Translator) buildStreamQuery(sql *strings.Builder, query *models.Query, baseTableName string) {
	// Build SELECT clause with specified fields
	sql.WriteString("SELECT ")

	if len(query.SelectFields) > 0 {
		sql.WriteString(strings.Join(query.SelectFields, ", "))
	} else {
		sql.WriteString("*")
	}

	sql.WriteString(" FROM table(")
	sql.WriteString(baseTableName)
	sql.WriteString(")")

	// Build WHERE clause
	var whereClauses []string

	if len(query.Conditions) > 0 {
		conditionsStr := t.buildProtonWhere(query.Conditions, query.Entity)
		whereClauses = append(whereClauses, conditionsStr)
	}

	if len(whereClauses) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(strings.Join(whereClauses, " AND "))
	}

	// Add GROUP BY if specified
	if len(query.GroupBy) > 0 {
		sql.WriteString(" GROUP BY ")
		sql.WriteString(strings.Join(query.GroupBy, ", "))
	}

	// Add ORDER BY if specified
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

	// Add LIMIT if specified
	if query.HasLimit {
		fmt.Fprintf(sql, " LIMIT %d", query.Limit)
	}
}

// buildProtonStreamingQuery builds a SQL query for Timeplus Proton WITHOUT table() wrapper for streaming
func (t *Translator) buildProtonStreamingQuery(query *models.Query) (string, error) {
	if query == nil {
		return "", errCannotTranslateNilQueryProton
	}

	var sql strings.Builder
	baseTableName := t.getProtonBaseTableName(query.Entity)

	// Build SELECT clause
	switch query.Type {
	case models.Show, models.Find:
		if query.Function != "" {
			sql.WriteString("SELECT ")
			sql.WriteString(t.buildFunctionCall(query))
			sql.WriteString(" FROM ")
		} else {
			sql.WriteString("SELECT * FROM ")
		}
	case models.Count:
		sql.WriteString("SELECT count() FROM ")
	case models.Stream:
		sql.WriteString("SELECT ")
		if len(query.SelectFields) > 0 {
			sql.WriteString(strings.Join(query.SelectFields, ", "))
		} else {
			sql.WriteString("*")
		}
		sql.WriteString(" FROM ")
	}

	// Add table name WITHOUT table() wrapper for streaming
	sql.WriteString(baseTableName)

	// Build WHERE clause
	var whereClauses []string

	if len(query.Conditions) > 0 {
		conditionsStr := t.buildProtonWhere(query.Conditions, query.Entity)
		whereClauses = append(whereClauses, conditionsStr)
	}

	// Skip the implicit filter for deleted devices in streaming mode
	// as it might interfere with real-time streaming

	if len(whereClauses) > 0 {
		sql.WriteString(" WHERE ")
		sql.WriteString(strings.Join(whereClauses, " AND "))
	}

	// ORDER BY clause (if applicable for streaming)
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

	// LIMIT clause (if applicable for streaming)
	if query.HasLimit {
		fmt.Fprintf(&sql, " LIMIT %d", query.Limit)
	}

	return sql.String(), nil
}

// buildClickHouseStreamingQuery builds a streaming SQL query for ClickHouse (without special wrappers)
func (t *Translator) buildClickHouseStreamingQuery(query *models.Query) (string, error) {
	// For ClickHouse, streaming queries are the same as regular queries
	// since ClickHouse doesn't use table() wrapper
	return t.buildClickHouseQuery(query)
}

// buildFunctionCall builds a function call like DISTINCT(field) for SQL
func (*Translator) buildFunctionCall(query *models.Query) string {
	funcName := strings.ToUpper(query.Function)

	if len(query.FunctionArgs) == 0 {
		return funcName + "()"
	}

	// For DISTINCT, we want to generate: DISTINCT field_name
	if funcName == "DISTINCT" {
		return fmt.Sprintf("DISTINCT %s", strings.Join(query.FunctionArgs, ", "))
	}

	// For other functions, use standard function call syntax
	return fmt.Sprintf("%s(%s)", funcName, strings.Join(query.FunctionArgs, ", "))
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

// formatProtonOrClickHouseTimestampCondition formats timestamp conditions with TODAY/YESTERDAY for Proton or ClickHouse
func (*Translator) formatProtonOrClickHouseTimestampCondition(fieldName, operator, dateValue string) string {
	var dateFunc string
	if dateValue == defaultToday {
		dateFunc = "today()"
	} else {
		// Must be YESTERDAY
		dateFunc = "yesterday()"
	}

	return fmt.Sprintf("%s %s %s", fieldName, operator, dateFunc)
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
func (t *Translator) formatCondition(cond *models.Condition, formatters conditionFormatters, entity models.EntityType) string {
	rawFieldName := cond.Field // Can be "field" or "func(field)"
	operator := cond.Operator
	rawValue := cond.Value

	// Handle date(field) = TODAY/YESTERDAY specifically
	if lowerRawFieldName := strings.ToLower(rawFieldName); strings.HasPrefix(lowerRawFieldName, "date(") &&
		operator == models.Equals {
		translatedFieldName := t.translateFieldNameWithEntity(rawFieldName, entity)
		if result, handled := t.formatDateCondition(rawFieldName, translatedFieldName, rawValue); handled {
			return result
		}
	}

	// Fallback to existing generic formatters
	fieldName := t.translateFieldNameWithEntity(rawFieldName, entity)

	return t.formatOperatorCondition(fieldName, cond, formatters)
}

// buildWhereClause builds a WHERE clause for the specified database type
func (t *Translator) buildWhereClause(conditions []models.Condition, entity models.EntityType, dbType DatabaseType) string {
	var formatters conditionFormatters

	var recursiveFunc func([]models.Condition) string

	switch dbType {
	case Proton:
		formatters = conditionFormatters{
			comparison: t.formatComparisonCondition,
			like:       t.formatProtonLikeCondition,
			contains:   t.formatProtonContainsCondition,
			in:         t.formatProtonInCondition,
			between:    t.formatProtonBetweenCondition,
			is:         t.formatProtonIsCondition,
		}
		recursiveFunc = func(nestedConds []models.Condition) string {
			return t.buildWhereClause(nestedConds, entity, Proton)
		}
	case ClickHouse:
		formatters = conditionFormatters{
			comparison: t.formatComparisonCondition,
			like:       t.formatLikeCondition,
			contains:   t.formatContainsCondition,
			in:         t.formatInCondition,
			between:    t.formatBetweenCondition,
			is:         t.formatIsCondition,
		}
		recursiveFunc = func(nestedConds []models.Condition) string {
			return t.buildWhereClause(nestedConds, entity, ClickHouse)
		}
	}

	return t.buildConditionString(
		conditions,
		func(cond *models.Condition) string {
			return t.formatCondition(cond, formatters, entity)
		},
		recursiveFunc,
	)
}

// buildProtonWhere builds a WHERE clause for Proton SQL.
func (t *Translator) buildProtonWhere(conditions []models.Condition, entity models.EntityType) string {
	return t.buildWhereClause(conditions, entity, Proton)
}

// buildClickHouseWhere builds a WHERE clause for ClickHouse SQL.
func (t *Translator) buildClickHouseWhere(conditions []models.Condition, entity models.EntityType) string {
	return t.buildWhereClause(conditions, entity, ClickHouse)
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

	// Handle TODAY/YESTERDAY for timestamp fields
	if valueStr, ok := value.(string); ok {
		upperVal := strings.ToUpper(valueStr)
		if upperVal == defaultToday || upperVal == defaultYesterday {
			switch t.DBType {
			case Proton, ClickHouse:
				return t.formatProtonOrClickHouseTimestampCondition(fieldName, t.translateOperator(op), upperVal)
			}
		}
	}

	if lowerField == "discovery_sources" {
		formatted := t.formatGenericValue(value, t.DBType)

		switch t.DBType {
		case Proton, ClickHouse:
			if op == models.Equals {
				// Translates to: has(discovery_sources, 'netbox')
				return fmt.Sprintf("has(%s, %s)", lowerField, formatted)
			}

			if op == models.NotEquals {
				// Translates to: NOT has(discovery_sources, 'netbox')
				return fmt.Sprintf("NOT has(%s, %s)", lowerField, formatted)
			}
		}
	}

	// fieldName is now pre-translated if it was a function like to_date(timestamp)
	// Value is the original value from the query (e.g. "some_string", 123)
	// It does NOT include "TODAY" or "YESTERDAY" here if handled above.
	return fmt.Sprintf("%s %s %s", fieldName, t.translateOperator(op), t.formatGenericValue(value, t.DBType))
}

func (t *Translator) formatGenericValue(value interface{}, dbType DatabaseType) string {
	// This function should handle basic types correctly for each DB.
	// It should NOT re-interpret "TODAY" or "YESTERDAY" as they are handled earlier.
	switch dbType {
	case Proton:
		return t.formatProtonValue(value)
	case ClickHouse:
		return t.formatClickHouseValue(value)
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

// formatProtonValue formats a value for Proton SQL
func (*Translator) formatProtonValue(value interface{}) string {
	switch v := value.(type) {
	case models.SQLExpression:
		return v.Expression // Return raw SQL expression without quoting
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		// For Proton/ClickHouse, boolean values should be unquoted literals
		if v {
			return defaultBoolValueTrue
		}

		return defaultBoolValueFalse
	case time.Time:
		// Format time as RFC3339 string with quotes for SQL
		return fmt.Sprintf("'%s'", v.Format(time.RFC3339))
	default:
		return fmt.Sprintf("%v", v)
	}
}

// formatClickHouseValue formats a value for ClickHouse SQL
func (*Translator) formatClickHouseValue(value interface{}) string {
	switch v := value.(type) {
	case models.SQLExpression:
		return v.Expression // Return raw SQL expression without quoting
	case string:
		return fmt.Sprintf("'%s'", strings.ReplaceAll(v, "'", "\\'"))
	case bool:
		// For ClickHouse, boolean values should be unquoted literals
		if v {
			return defaultBoolValueTrue
		}

		return defaultBoolValueFalse
	case time.Time:
		// Format time as RFC3339 string with quotes for SQL
		return fmt.Sprintf("'%s'", v.Format(time.RFC3339))
	default:
		return fmt.Sprintf("%v", v)
	}
}

// getEntityFieldMapData returns field mappings for specific entities
func getEntityFieldMapData() map[models.EntityType]map[string]string {
	return map[models.EntityType]map[string]string{
		models.Logs: {
			"severity": "severity_text",
			"level":    "severity_text",
			"service":  "service_name",
			"trace":    "trace_id",
			"span":     "span_id",
		},
		models.OtelTraces: {
			"trace":       "trace_id",
			"span":        "span_id",
			"service":     "service_name",
			"name":        "name",
			"kind":        "kind",
			"start":       "start_time_unix_nano",
			"end":         "end_time_unix_nano",
			"duration_ms": "(end_time_unix_nano - start_time_unix_nano) / 1e6",
		},
		models.OtelMetrics: {
			"trace":   "trace_id",
			"span":    "span_id",
			"service": "service_name",
			"route":   "http_route",
			"method":  "http_method",
			"status":  "http_status_code",
		},
		models.OtelTraceSummaries: {
			"trace":       "trace_id",
			"service":     "root_service_name",
			"duration_ms": "duration_ms",
			"status":      "status_code",
			"span_count":  "span_count",
			"errors":      "error_count",
			"start":       "start_time_unix_nano",
			"end":         "end_time_unix_nano",
			"root_span":   "root_span_name",
		},
		models.OtelSpansEnriched: {
			"trace":       "trace_id",
			"span":        "span_id",
			"service":     "service_name",
			"name":        "name",
			"kind":        "kind",
			"duration_ms": "duration_ms",
			"is_root":     "is_root",
			"parent":      "parent_span_id",
			"start":       "start_time_unix_nano",
			"end":         "end_time_unix_nano",
		},
		models.OtelRootSpans: {
			"trace":   "trace_id",
			"span":    "root_span_id",
			"name":    "root_span_name",
			"kind":    "root_kind",
			"service": "root_service",
		},
	}
}

// translateFieldNameWithEntity translates field names with entity-specific mappings
func (t *Translator) translateFieldNameWithEntity(fieldName string, entity models.EntityType) string {
	lowerFieldName := strings.ToLower(fieldName)

	// Handle date() functions first
	if strings.HasPrefix(lowerFieldName, "date(") && strings.HasSuffix(lowerFieldName, ")") {
		// Extract actual field name from "date(actual_field)"
		innerField := strings.TrimSuffix(strings.TrimPrefix(lowerFieldName, "date("), ")")

		// Apply entity-specific mapping to the inner field
		entityFieldMap := getEntityFieldMapData()
		if fieldMappings, exists := entityFieldMap[entity]; exists {
			if mappedField, exists := fieldMappings[innerField]; exists {
				innerField = mappedField
			}
		}

		if t.DBType == Proton {
			return fmt.Sprintf("to_date(%s)", innerField)
		}

		if t.DBType == ClickHouse {
			return fmt.Sprintf("toDate(%s)", innerField)
		}
	}

	// Apply entity-specific field mappings
	entityFieldMap := getEntityFieldMapData()
	if fieldMappings, exists := entityFieldMap[entity]; exists {
		if mappedField, exists := fieldMappings[lowerFieldName]; exists {
			return mappedField
		}
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

// convertTimeClauseToCondition converts time clauses to WHERE conditions
func (t *Translator) convertTimeClauseToCondition(query *models.Query) {
	if query.TimeClause == nil {
		return
	}

	// Determine the timestamp field based on entity type
	timestampField := t.getTimestampFieldForEntity(query.Entity)

	// Convert time clause to condition
	condition := t.timeClauseToCondition(query.TimeClause, timestampField)

	// Add logical operator to existing conditions if we're adding a new one
	if len(query.Conditions) > 0 {
		// Add AND to the first existing condition
		query.Conditions[0].LogicalOp = models.And
	}

	// Prepend the time condition to existing conditions
	query.Conditions = append([]models.Condition{condition}, query.Conditions...)

	// Clear the time clause since it's now a condition
	query.TimeClause = nil
}

// getTimestampFieldForEntity returns the appropriate timestamp field for an entity
func (*Translator) getTimestampFieldForEntity(entity models.EntityType) string {
	configs := getEntityConfigurations()
	if config, exists := configs[entity]; exists {
		return config.timestampField
	}
	// Default fallback for any new entity types
	return "timestamp"
}

// timeClauseToCondition converts a TimeClause to a Condition
func (t *Translator) timeClauseToCondition(tc *models.TimeClause, timestampField string) models.Condition {
	switch tc.Type {
	case models.TimeToday:
		// Use timestamp range for today: timestamp >= start_of_today AND timestamp < start_of_tomorrow
		startOfDayFunc := t.getStartOfDayFunction()

		return models.Condition{
			Field:    timestampField,
			Operator: models.GreaterThanOrEquals,
			Value:    models.SQLExpression{Expression: fmt.Sprintf("%s(now())", startOfDayFunc)},
		}
	case models.TimeYesterday:
		// Use timestamp range for yesterday: timestamp >= start_of_yesterday AND timestamp < start_of_today
		startOfDayFunc := t.getStartOfDayFunction()

		return models.Condition{
			Field:    timestampField,
			Operator: models.Between,
			Values: []interface{}{
				models.SQLExpression{Expression: fmt.Sprintf("%s(yesterday())", startOfDayFunc)},
				models.SQLExpression{Expression: fmt.Sprintf("%s(today())", startOfDayFunc)},
			},
		}
	case models.TimeLast:
		// For "LAST n timeUnit", create a condition like: timestamp >= NOW() - INTERVAL n timeUnit
		intervalValue := fmt.Sprintf("NOW() - INTERVAL %d %s", tc.Amount, strings.ToUpper(string(tc.Unit)))

		return models.Condition{
			Field:    timestampField,
			Operator: models.GreaterThanOrEquals,
			Value:    models.SQLExpression{Expression: intervalValue},
		}
	case models.TimeRange:
		// For BETWEEN ranges, create a BETWEEN condition
		return models.Condition{
			Field:    timestampField,
			Operator: models.Between,
			Values:   []interface{}{tc.StartValue, tc.EndValue},
		}

	default:
		startOfDayFunc := t.getStartOfDayFunction()

		return models.Condition{
			Field:    timestampField,
			Operator: models.GreaterThanOrEquals,
			Value:    models.SQLExpression{Expression: fmt.Sprintf("%s(now())", startOfDayFunc)},
		}
	}
}

// getStartOfDayFunction returns the correct start-of-day function for the database type
func (t *Translator) getStartOfDayFunction() string {
	switch t.DBType {
	case Proton:
		return "to_start_of_day"
	case ClickHouse:
		return "toStartOfDay"
	default:
		return "toStartOfDay" // default to ClickHouse syntax
	}
}
