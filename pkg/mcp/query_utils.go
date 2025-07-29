package mcp

import (
	"context"
	"encoding/json"
	"fmt"
)

const (
	showLogsQuery    = "SHOW logs"
	showEventsQuery  = "SHOW events"
	showDevicesQuery = "SHOW devices"
	defaultLimit     = 100
)

// getEntityTimestampField returns the appropriate timestamp field name for each entity type
func getEntityTimestampField(entity string) string {
	switch entity {
	case "events":
		return "event_timestamp"
	case "logs":
		return "timestamp"
	case "devices":
		return "last_seen"
	case "flows":
		return "timestamp"
	case "traps":
		return "timestamp"
	default:
		return "timestamp" // Default fallback
	}
}

type LogQueryParams struct {
	Filter    string `json:"filter,omitempty"`
	StartTime string `json:"start_time,omitempty"`
	EndTime   string `json:"end_time,omitempty"`
	Limit     int    `json:"limit,omitempty"`
}

type RecentLogsParams struct {
	Limit    int    `json:"limit,omitempty"`
	PollerID string `json:"poller_id,omitempty"`
}

type ListDevicesParams struct {
	Limit  int    `json:"limit,omitempty"`
	Type   string `json:"type,omitempty"`
	Status string `json:"status,omitempty"`
}

type QueryExecutor interface {
	ExecuteSRQLQuery(ctx context.Context, query string, limit int) ([]map[string]interface{}, error)
}

func buildLogQuery(params LogQueryParams) string {
	query := showLogsQuery
	conditions := []string{}

	if params.Filter != "" {
		conditions = append(conditions, params.Filter)
	}

	if params.StartTime != "" {
		conditions = append(conditions, fmt.Sprintf("timestamp >= '%s'", params.StartTime))
	}

	if params.EndTime != "" {
		conditions = append(conditions, fmt.Sprintf("timestamp <= '%s'", params.EndTime))
	}

	if len(conditions) > 0 {
		query += " WHERE " + conditions[0]
		for _, condition := range conditions[1:] {
			query += " AND " + condition
		}
	}

	query += " ORDER BY timestamp DESC"

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query += fmt.Sprintf(" LIMIT %d", params.Limit)

	return query
}

func buildRecentLogsQuery(params RecentLogsParams) string {
	query := showLogsQuery

	if params.PollerID != "" {
		query += fmt.Sprintf(" WHERE poller_id = '%s'", params.PollerID)
	}

	if params.Limit <= 0 {
		params.Limit = defaultLimit
	}

	query += fmt.Sprintf(" ORDER BY timestamp DESC LIMIT %d", params.Limit)

	return query
}

func executeQueryLogs(ctx context.Context, args json.RawMessage, executor QueryExecutor) ([]map[string]interface{}, error) {
	var params LogQueryParams

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	query := buildLogQuery(params)

	return executor.ExecuteSRQLQuery(ctx, query, params.Limit)
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

	query := buildRecentLogsQuery(params)

	return executor.ExecuteSRQLQuery(ctx, query, params.Limit)
}

func buildDevicesQuery(params ListDevicesParams) string {
	query := showDevicesQuery
	conditions := []string{}

	if params.Type != "" {
		conditions = append(conditions, fmt.Sprintf("device_type = '%s'", params.Type))
	}

	if params.Status != "" {
		conditions = append(conditions, fmt.Sprintf("status = '%s'", params.Status))
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

	return query
}

func executeListDevices(ctx context.Context, args json.RawMessage, executor QueryExecutor) ([]map[string]interface{}, error) {
	var params ListDevicesParams

	if len(args) > 0 {
		if err := json.Unmarshal(args, &params); err != nil {
			return nil, err
		}
	}

	query := buildDevicesQuery(params)

	return executor.ExecuteSRQLQuery(ctx, query, params.Limit)
}
