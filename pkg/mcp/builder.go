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
	"strings"
	"time"
)

// BuildSRQL constructs an SRQL query from tool arguments
func BuildSRQL(entity, filter, orderBy string, limit int, sortDesc bool) string {
	var query strings.Builder
	
	// Start with SELECT
	query.WriteString("SELECT * FROM ")
	query.WriteString(entity)
	
	// Add WHERE clause if filter is provided
	if filter != "" {
		query.WriteString(" WHERE ")
		query.WriteString(filter)
	}
	
	// Add ORDER BY clause if specified
	if orderBy != "" {
		query.WriteString(" ORDER BY ")
		query.WriteString(orderBy)
		if sortDesc {
			query.WriteString(" DESC")
		}
	}
	
	// Add LIMIT clause if specified
	if limit > 0 {
		query.WriteString(fmt.Sprintf(" LIMIT %d", limit))
	}
	
	return query.String()
}

// BuildTimeRangeFilter creates a time range filter for SRQL queries
func BuildTimeRangeFilter(startTime, endTime *time.Time, timestampField string) string {
	if startTime == nil && endTime == nil {
		return ""
	}
	
	var conditions []string
	
	if startTime != nil {
		conditions = append(conditions, fmt.Sprintf("%s >= '%s'", timestampField, startTime.Format(time.RFC3339)))
	}
	
	if endTime != nil {
		conditions = append(conditions, fmt.Sprintf("%s <= '%s'", timestampField, endTime.Format(time.RFC3339)))
	}
	
	return strings.Join(conditions, " AND ")
}

// CombineFilters combines multiple filter conditions with AND
func CombineFilters(filters ...string) string {
	var nonEmptyFilters []string
	
	for _, filter := range filters {
		if strings.TrimSpace(filter) != "" {
			nonEmptyFilters = append(nonEmptyFilters, fmt.Sprintf("(%s)", filter))
		}
	}
	
	return strings.Join(nonEmptyFilters, " AND ")
}