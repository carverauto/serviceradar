/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package mcp

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/carverauto/serviceradar/pkg/srql/models"
)

// ConvertSRQLToSQL converts a parsed SRQL query to SQL
func ConvertSRQLToSQL(queryInterface interface{}) (string, error) {
	query, ok := queryInterface.(*models.Query)
	if !ok {
		return "", fmt.Errorf("invalid query type: expected *models.Query")
	}

	var sql strings.Builder

	// Build the SELECT clause
	switch query.Type {
	case models.Show:
		if query.Function != "" {
			// Handle function calls like DISTINCT
			sql.WriteString(fmt.Sprintf("SELECT %s(", strings.ToUpper(query.Function)))
			if len(query.FunctionArgs) > 0 {
				sql.WriteString(strings.Join(query.FunctionArgs, ", "))
			} else {
				sql.WriteString("*")
			}
			sql.WriteString(")")
		} else {
			sql.WriteString("SELECT *")
		}
	case models.Find:
		sql.WriteString("SELECT *")
	case models.Count:
		sql.WriteString("SELECT COUNT(*)")
	case models.Stream:
		if len(query.SelectFields) > 0 {
			sql.WriteString("SELECT ")
			sql.WriteString(strings.Join(query.SelectFields, ", "))
		} else {
			sql.WriteString("SELECT *")
		}
	default:
		sql.WriteString("SELECT *")
	}

	// Add FROM clause
	tableName := getTableName(query.Entity)
	sql.WriteString(fmt.Sprintf(" FROM %s", tableName))

	// Add WHERE clause if conditions exist
	if len(query.Conditions) > 0 {
		whereClause, err := buildWhereClause(query.Conditions)
		if err != nil {
			return "", fmt.Errorf("failed to build WHERE clause: %w", err)
		}
		sql.WriteString(" WHERE ")
		sql.WriteString(whereClause)
	}

	// Add GROUP BY clause for STREAM queries
	if query.Type == models.Stream && len(query.GroupBy) > 0 {
		sql.WriteString(" GROUP BY ")
		sql.WriteString(strings.Join(query.GroupBy, ", "))
	}

	// Add ORDER BY clause
	if len(query.OrderBy) > 0 {
		sql.WriteString(" ORDER BY ")
		var orderItems []string
		for _, item := range query.OrderBy {
			direction := "ASC"
			if item.Direction == models.Descending {
				direction = "DESC"
			}
			orderItems = append(orderItems, fmt.Sprintf("%s %s", item.Field, direction))
		}
		sql.WriteString(strings.Join(orderItems, ", "))
	}

	// Add LIMIT clause
	if query.HasLimit && query.Limit > 0 {
		sql.WriteString(fmt.Sprintf(" LIMIT %d", query.Limit))
	}

	return sql.String(), nil
}

// getTableName maps SRQL entity types to actual table names
func getTableName(entity models.EntityType) string {
	switch entity {
	case models.Devices:
		return "devices"
	case models.DeviceUpdates:
		return "device_updates"
	case models.Logs:
		return "logs"
	case models.Events:
		return "events"
	case models.ICMPResults:
		return "icmp_results"
	case models.SNMPResults:
		return "snmp_results"
	case models.SNMPMetrics:
		return "snmp_metrics"
	case models.CPUMetrics:
		return "cpu_metrics"
	case models.DiskMetrics:
		return "disk_metrics"
	case models.MemoryMetrics:
		return "memory_metrics"
	case models.ProcessMetrics:
		return "process_metrics"
	case models.Flows:
		return "flows"
	case models.Traps:
		return "traps"
	case models.Connections:
		return "connections"
	case models.Services:
		return "services"
	case models.Interfaces:
		return "interfaces"
	case models.Pollers:
		return "pollers"
	default:
		// Default to the entity name as string
		return string(entity)
	}
}

// buildWhereClause constructs the WHERE clause from conditions
func buildWhereClause(conditions []models.Condition) (string, error) {
	if len(conditions) == 0 {
		return "", nil
	}

	var parts []string
	
	for i, condition := range conditions {
		conditionSQL, err := buildCondition(condition)
		if err != nil {
			return "", err
		}
		
		if i > 0 {
			// Add logical operator from previous condition
			if i-1 < len(conditions) && conditions[i-1].LogicalOp != "" {
				parts = append(parts, string(conditions[i-1].LogicalOp))
			} else {
				parts = append(parts, "AND") // Default to AND
			}
		}
		
		parts = append(parts, conditionSQL)
	}

	return strings.Join(parts, " "), nil
}

// buildCondition constructs a single condition
func buildCondition(condition models.Condition) (string, error) {
	if condition.IsComplex {
		// Handle complex nested conditions
		nestedClause, err := buildWhereClause(condition.Complex)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("(%s)", nestedClause), nil
	}

	// Handle simple conditions
	switch condition.Operator {
	case models.Equals, models.NotEquals, models.GreaterThan, models.GreaterThanOrEquals,
		 models.LessThan, models.LessThanOrEquals:
		return fmt.Sprintf("%s %s %s", condition.Field, condition.Operator, formatValue(condition.Value)), nil
		
	case models.Like:
		return fmt.Sprintf("%s LIKE %s", condition.Field, formatValue(condition.Value)), nil
		
	case models.In:
		if len(condition.Values) == 0 {
			return "", fmt.Errorf("IN operator requires values")
		}
		var valueStrings []string
		for _, val := range condition.Values {
			valueStrings = append(valueStrings, formatValue(val))
		}
		return fmt.Sprintf("%s IN (%s)", condition.Field, strings.Join(valueStrings, ", ")), nil
		
	case models.Between:
		if len(condition.Values) != 2 {
			return "", fmt.Errorf("BETWEEN operator requires exactly 2 values")
		}
		return fmt.Sprintf("%s BETWEEN %s AND %s", condition.Field, 
			formatValue(condition.Values[0]), formatValue(condition.Values[1])), nil
			
	case models.Is:
		// Handle IS NULL, IS NOT NULL
		return fmt.Sprintf("%s IS %s", condition.Field, formatValue(condition.Value)), nil
		
	case models.Contains:
		// Convert CONTAINS to LIKE with wildcards
		return fmt.Sprintf("%s LIKE '%%%s%%'", condition.Field, formatValue(condition.Value)), nil
		
	default:
		return "", fmt.Errorf("unsupported operator: %s", condition.Operator)
	}
}

// formatValue formats a value for SQL, handling proper quoting
func formatValue(value interface{}) string {
	if value == nil {
		return "NULL"
	}
	
	switch v := value.(type) {
	case string:
		// Escape single quotes and wrap in quotes
		escaped := strings.ReplaceAll(v, "'", "''")
		return fmt.Sprintf("'%s'", escaped)
	case int, int32, int64:
		return fmt.Sprintf("%d", v)
	case float32, float64:
		return fmt.Sprintf("%f", v)
	case bool:
		if v {
			return "TRUE"
		}
		return "FALSE"
	default:
		// Try to convert to string and quote
		str := fmt.Sprintf("%v", v)
		// Check if it's a number
		if _, err := strconv.ParseFloat(str, 64); err == nil {
			return str
		}
		// Otherwise quote it
		escaped := strings.ReplaceAll(str, "'", "''")
		return fmt.Sprintf("'%s'", escaped)
	}
}