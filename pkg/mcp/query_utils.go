package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

const (
	showLogsQuery    = "SHOW logs"
	showEventsQuery  = "SHOW events"
	showDevicesQuery = "SHOW devices"
	defaultLimit     = 100
)

var errParameterizedSRQLNotSupported = errors.New("query executor does not support parameterized SRQL queries")

// getEntityTimestampField returns the appropriate timestamp field name for each entity type
func getEntityTimestampField(entity string) string {
	switch entity {
	case "events":
		return "event_timestamp"
	case "logs":
		return defaultOrderBy
	case "devices":
		return "last_seen"
	case "flows":
		return defaultOrderBy
	case "traps":
		return defaultOrderBy
	default:
		return defaultOrderBy // Default fallback
	}
}

// LogQueryParams defines parameters for querying log entries.
type LogQueryParams struct {
	Filter    string `json:"filter,omitempty"`
	StartTime string `json:"start_time,omitempty"`
	EndTime   string `json:"end_time,omitempty"`
	Limit     int    `json:"limit,omitempty"`
}

// RecentLogsParams defines parameters for retrieving recent log entries.
type RecentLogsParams struct {
	Limit    int    `json:"limit,omitempty"`
	GatewayID string `json:"gateway_id,omitempty"`
}

// ListDevicesParams defines parameters for listing devices.
type ListDevicesParams struct {
	Limit  int    `json:"limit,omitempty"`
	Type   string `json:"type,omitempty"`
	Status string `json:"status,omitempty"`
}

// QueryExecutor defines the interface for executing SRQL queries.
type QueryExecutor interface {
	ExecuteSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error)
}

// ParameterizedQueryExecutor extends QueryExecutor with parameter binding support.
// Implementations MUST treat params as bound values (not text concatenated into query).
type ParameterizedQueryExecutor interface {
	QueryExecutor
	ExecuteSRQLQueryWithParams(ctx context.Context, query string, params []any, limit int) ([]map[string]interface{}, error)
}

func executeSRQL(ctx context.Context, executor QueryExecutor, query string, params []any, limit int) ([]map[string]interface{}, error) {
	if len(params) == 0 {
		return executor.ExecuteSRQLQuery(ctx, query, limit)
	}

	parameterized, ok := executor.(ParameterizedQueryExecutor)
	if !ok {
		return nil, fmt.Errorf("%w", errParameterizedSRQLNotSupported)
	}

	return parameterized.ExecuteSRQLQueryWithParams(ctx, query, params, limit)
}

func buildLogQuery(params LogQueryParams) (string, []any) {
	query := showLogsQuery
	conditions := []string{}
	binds := &srqlBindBuilder{}

	if params.Filter != "" {
		conditions = append(conditions, params.Filter)
	}

	if params.StartTime != "" {
		conditions = append(conditions, fmt.Sprintf("_tp_time >= %s", binds.Bind(params.StartTime)))
	}

	if params.EndTime != "" {
		conditions = append(conditions, fmt.Sprintf("_tp_time <= %s", binds.Bind(params.EndTime)))
	}

	if len(conditions) > 0 {
		query += " WHERE " + conditions[0]
		for _, condition := range conditions[1:] {
			query += " AND " + condition
		}
	}

	query += " ORDER BY _tp_time DESC"

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query += fmt.Sprintf(" LIMIT %d", params.Limit)

	return query, binds.params
}

func buildRecentLogsQuery(params RecentLogsParams) (string, []any) {
	query := showLogsQuery

	binds := &srqlBindBuilder{}
	if params.GatewayID != "" {
		query += fmt.Sprintf(" WHERE gateway_id = %s", binds.Bind(params.GatewayID))
	}

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query += fmt.Sprintf(" ORDER BY _tp_time DESC LIMIT %d", params.Limit)

	return query, binds.params
}

func executeQueryLogs(ctx context.Context, args json.RawMessage, executor QueryExecutor) ([]map[string]interface{}, error) {
	var params LogQueryParams

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	query, binds := buildLogQuery(params)
	return executeSRQL(ctx, executor, query, binds, params.Limit)
}

func executeGetRecentLogs(ctx context.Context, args json.RawMessage, executor QueryExecutor) ([]map[string]interface{}, error) {
	var params RecentLogsParams

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query, binds := buildRecentLogsQuery(params)
	return executeSRQL(ctx, executor, query, binds, params.Limit)
}

func buildDevicesQuery(params ListDevicesParams) (string, []any) {
	query := showDevicesQuery

	binds := &srqlBindBuilder{}
	var conditions []string

	if params.Type != "" {
		conditions = append(conditions, fmt.Sprintf("device_type = %s", binds.Bind(params.Type)))
	}

	if params.Status != "" {
		// Map status values to is_available boolean field
		var condition string

		switch params.Status {
		case "active", "online", "available":
			condition = "is_available = true"
		case "inactive", "offline", "unavailable":
			condition = "is_available = false"
		default:
			// If it's a boolean string, use it directly
			if params.Status == "true" || params.Status == "false" {
				condition = fmt.Sprintf("is_available = %s", params.Status)
			} else {
				// Fallback: assume it's a custom status field
				condition = fmt.Sprintf("status = %s", binds.Bind(params.Status))
			}
		}

		conditions = append(conditions, condition)
	}

	if len(conditions) > 0 {
		query += " WHERE " + conditions[0]
		for _, condition := range conditions[1:] {
			query += " AND " + condition
		}
	}

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query += fmt.Sprintf(" LIMIT %d", params.Limit)

	return query, binds.params
}

func executeListDevices(ctx context.Context, args json.RawMessage, executor QueryExecutor) ([]map[string]interface{}, error) {
	var params ListDevicesParams

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	query, binds := buildDevicesQuery(params)
	return executeSRQL(ctx, executor, query, binds, params.Limit)
}
