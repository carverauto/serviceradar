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

// Package api pkg/core/api/query_test.go
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/srql/models" // <--- FIX #1: ADDED THIS IMPORT
	"github.com/carverauto/serviceradar/pkg/srql/parser"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

// TestValidateQueryRequest tests the validateQueryRequest function
func TestValidateQueryRequest(t *testing.T) {
	tests := []struct {
		name           string
		req            *QueryRequest
		expectedErrMsg string
		expectedStatus int
		expectedOK     bool
	}{
		{
			name:           "Empty query",
			req:            &QueryRequest{Query: ""},
			expectedErrMsg: "Query string is required",
			expectedStatus: http.StatusBadRequest,
			expectedOK:     false,
		},
		{
			name:           "Valid query with default limit",
			req:            &QueryRequest{Query: "show devices"},
			expectedErrMsg: "",
			expectedStatus: 0,
			expectedOK:     true,
		},
		{
			name:           "Valid query with custom limit",
			req:            &QueryRequest{Query: "show devices", Limit: 20},
			expectedErrMsg: "",
			expectedStatus: 0,
			expectedOK:     true,
		},
		{
			name:           "Invalid direction",
			req:            &QueryRequest{Query: "show devices", Direction: "invalid"},
			expectedErrMsg: "Direction must be 'next' or 'prev'",
			expectedStatus: http.StatusBadRequest,
			expectedOK:     false,
		},
		{
			name:           "Valid direction next",
			req:            &QueryRequest{Query: "show devices", Direction: DirectionNext},
			expectedErrMsg: "",
			expectedStatus: 0,
			expectedOK:     true,
		},
		{
			name:           "Valid direction prev",
			req:            &QueryRequest{Query: "show devices", Direction: DirectionPrev},
			expectedErrMsg: "",
			expectedStatus: 0,
			expectedOK:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			errMsg, statusCode, ok := validateQueryRequest(tt.req)
			assert.Equal(t, tt.expectedErrMsg, errMsg)
			assert.Equal(t, tt.expectedStatus, statusCode)
			assert.Equal(t, tt.expectedOK, ok)

			// Check if limit is set to default when not specified
			if tt.req.Limit <= 0 && ok {
				assert.Equal(t, 10, tt.req.Limit, "Default limit should be 10")
			}
		})
	}
}

// TestPrepareQuery tests the prepareQuery method
func TestPrepareQuery(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name          string
		req           *QueryRequest
		dbType        parser.DatabaseType
		expectError   bool
		errorContains string
		setupMock     func(*APIServer)
		validateQuery func(*testing.T, *models.Query, map[string]interface{})
	}{
		{
			name: "Valid query for devices",
			req: &QueryRequest{
				Query: "show devices",
				Limit: 10,
			},
			dbType:      parser.Proton,
			expectError: false,
			setupMock:   func(*APIServer) {},
			validateQuery: func(t *testing.T, query *models.Query, _ map[string]interface{}) {
				t.Helper()

				assert.Equal(t, models.Devices, query.Entity)
				assert.Equal(t, 10, query.Limit)
				assert.True(t, query.HasLimit)
				assert.Len(t, query.OrderBy, 2) // Now expects 2 due to tie-breaker
				assert.Equal(t, "_tp_time", query.OrderBy[0].Field)
				assert.Equal(t, "ip", query.OrderBy[1].Field)
				assert.Equal(t, models.Descending, query.OrderBy[0].Direction)
			},
		},
		{
			name: "Valid query for interfaces",
			req: &QueryRequest{
				Query: "show interfaces",
				Limit: 20,
			},
			dbType:      parser.Proton,
			expectError: false,
			setupMock:   func(*APIServer) {},
			validateQuery: func(t *testing.T, query *models.Query, _ map[string]interface{}) {
				t.Helper()

				assert.Equal(t, models.Interfaces, query.Entity)
				assert.Equal(t, 20, query.Limit)
				assert.True(t, query.HasLimit)
				assert.Len(t, query.OrderBy, 1) // No tie-breaker for interfaces yet
				assert.Equal(t, "_tp_time", query.OrderBy[0].Field)
				assert.Equal(t, models.Descending, query.OrderBy[0].Direction)
			},
		},
		{
			name: "Valid query with cursor",
			req: &QueryRequest{
				Query:     "show devices",
				Limit:     10,
				Cursor:    "eyJpcCI6IjE5Mi4xNjguMS4xIiwibGFzdF9zZWVuIjoiMjAyNS0wNS0zMCAxMjowMDowMCJ9",
				Direction: DirectionNext,
			},
			dbType:      parser.Proton,
			expectError: false,
			setupMock:   func(*APIServer) {},
			validateQuery: func(t *testing.T, query *models.Query, cursorData map[string]interface{}) {
				t.Helper()

				assert.Equal(t, models.Devices, query.Entity)
				assert.Equal(t, 10, query.Limit)
				assert.True(t, query.HasLimit)
				assert.NotNil(t, cursorData)
				assert.Equal(t, "192.168.1.1", cursorData["ip"])
			},
		},
		{
			name: "Invalid entity",
			req: &QueryRequest{
				Query: "show flows",
				Limit: 10,
			},
			dbType:        parser.Proton,
			expectError:   true,
			errorContains: "pagination is only supported for", // Adjusted error message check
			setupMock:     func(*APIServer) {},
			validateQuery: nil,
		},
		{
			name: "Parse error",
			req: &QueryRequest{
				Query: "invalid query",
				Limit: 10,
			},
			dbType:        parser.Proton,
			expectError:   true,
			errorContains: "failed to parse query",
			setupMock:     func(*APIServer) {},
			validateQuery: nil,
		},
		{
			name: "Invalid cursor",
			req: &QueryRequest{
				Query:     "show devices",
				Limit:     10,
				Cursor:    "invalid-cursor",
				Direction: DirectionNext,
			},
			dbType:        parser.Proton,
			expectError:   true,
			errorContains: "invalid cursor",
			setupMock:     func(*APIServer) {},
			validateQuery: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &APIServer{
				dbType: tt.dbType,
			}

			tt.setupMock(s)

			query, cursorData, err := s.prepareQuery(tt.req)
			if tt.expectError {
				require.Error(t, err)

				if tt.errorContains != "" {
					assert.Contains(t, err.Error(), tt.errorContains)
				}

				return
			}

			require.NoError(t, err)
			require.NotNil(t, query)

			if tt.validateQuery != nil {
				tt.validateQuery(t, query, cursorData)
			}
		})
	}
}

// TestExecuteQueryAndBuildResponse tests the executeQueryAndBuildResponse method
func TestExecuteQueryAndBuildResponse(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockQueryExecutor := db.NewMockQueryExecutor(ctrl)

	tests := []struct {
		name          string
		query         *models.Query
		req           *QueryRequest
		dbType        parser.DatabaseType
		expectError   bool
		errorContains string
		setupMock     func()
		validateResp  func(*testing.T, *QueryResponse)
	}{
		{
			name: "Successful query execution with next cursor",
			query: &models.Query{
				Entity:   models.Devices,
				Limit:    2, // Set limit to match result count for next cursor generation
				HasLimit: true,
				OrderBy: []models.OrderByItem{
					{Field: "last_seen", Direction: models.Descending},
				},
			},
			req: &QueryRequest{
				Query: "show devices",
				Limit: 2,
			},
			dbType:      parser.Proton,
			expectError: false,
			setupMock: func() {
				mockQueryExecutor.EXPECT().
					ExecuteQuery(gomock.Any(), gomock.Any()).
					Return([]map[string]interface{}{
						{"ip": "192.168.1.1", "last_seen": time.Now()},
						{"ip": "192.168.1.2", "last_seen": time.Now().Add(-1 * time.Hour)},
					}, nil)
			},
			validateResp: func(t *testing.T, resp *QueryResponse) {
				t.Helper()
				assert.Len(t, resp.Results, 2)
				assert.Equal(t, 2, resp.Pagination.Limit)
				assert.NotEmpty(t, resp.Pagination.NextCursor)
				assert.NotEmpty(t, resp.Pagination.PrevCursor)
			},
		},
		{
			name: "Successful query execution without next cursor",
			query: &models.Query{
				Entity:   models.Devices,
				Limit:    10, // Request more than available
				HasLimit: true,
				OrderBy: []models.OrderByItem{
					{Field: "last_seen", Direction: models.Descending},
				},
			},
			req: &QueryRequest{
				Query: "show devices",
				Limit: 10,
			},
			dbType:      parser.Proton,
			expectError: false,
			setupMock: func() {
				mockQueryExecutor.EXPECT().
					ExecuteQuery(gomock.Any(), gomock.Any()).
					Return([]map[string]interface{}{ // Return fewer results than limit
						{"ip": "192.168.1.1", "last_seen": time.Now()},
						{"ip": "192.168.1.2", "last_seen": time.Now().Add(-1 * time.Hour)},
					}, nil)
			},
			validateResp: func(t *testing.T, resp *QueryResponse) {
				t.Helper()
				assert.Len(t, resp.Results, 2)
				assert.Equal(t, 10, resp.Pagination.Limit)
				assert.Empty(t, resp.Pagination.NextCursor, "Next cursor should be empty on the last page")
				assert.NotEmpty(t, resp.Pagination.PrevCursor)
			},
		},
		{
			name: "Query execution error",
			query: &models.Query{
				Entity: models.Devices,
				OrderBy: []models.OrderByItem{
					{Field: "last_seen", Direction: models.Descending},
				},
			},
			req: &QueryRequest{
				Query: "show devices",
				Limit: 10,
			},
			dbType:        parser.Proton,
			expectError:   true,
			errorContains: "failed to execute query",
			setupMock: func() {
				mockQueryExecutor.EXPECT().
					ExecuteQuery(gomock.Any(), gomock.Any()).
					Return(nil, assert.AnError)
			},
			validateResp: nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &APIServer{
				dbType:        tt.dbType,
				queryExecutor: mockQueryExecutor,
			}

			tt.setupMock()

			resp, err := s.executeQueryAndBuildResponse(context.Background(), tt.query, tt.req)
			if tt.expectError {
				require.Error(t, err)

				if tt.errorContains != "" {
					assert.Contains(t, err.Error(), tt.errorContains)
				}

				return
			}

			require.NoError(t, err)
			require.NotNil(t, resp)

			if tt.validateResp != nil {
				tt.validateResp(t, resp)
			}
		})
	}
}

// TestHandleSRQLQuery tests the handleSRQLQuery method
func TestHandleSRQLQuery(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockQueryExecutor := db.NewMockQueryExecutor(ctrl)

	tests := []struct {
		name           string
		requestBody    string
		dbType         parser.DatabaseType
		expectedStatus int
		setupMock      func()
		validateResp   func(*testing.T, *httptest.ResponseRecorder)
	}{
		{
			name:           "Valid query",
			requestBody:    `{"query": "show devices", "limit": 10}`,
			dbType:         parser.Proton,
			expectedStatus: http.StatusOK,
			setupMock: func() {
				// Mock the query execution
				mockQueryExecutor.EXPECT().
					ExecuteQuery(gomock.Any(), gomock.Any()).
					Return([]map[string]interface{}{
						{"ip": "192.168.1.1", "last_seen": time.Now()},
					}, nil)
			},
			validateResp: func(t *testing.T, w *httptest.ResponseRecorder) {
				t.Helper()
				assert.Equal(t, http.StatusOK, w.Code)

				var resp QueryResponse

				err := json.Unmarshal(w.Body.Bytes(), &resp)
				require.NoError(t, err)

				assert.Len(t, resp.Results, 1)
				assert.Equal(t, "192.168.1.1", resp.Results[0]["ip"])
				assert.Equal(t, 10, resp.Pagination.Limit)
			},
		},
		{
			name:           "Invalid JSON",
			requestBody:    `{"query": "show devices", "limit": }`,
			dbType:         parser.Proton,
			expectedStatus: http.StatusBadRequest,
			setupMock:      func() {},
			validateResp: func(t *testing.T, w *httptest.ResponseRecorder) {
				t.Helper()
				assert.Equal(t, http.StatusBadRequest, w.Code)

				var resp map[string]interface{}

				err := json.Unmarshal(w.Body.Bytes(), &resp)

				require.NoError(t, err)
				assert.Contains(t, resp["message"], "Invalid request body")
			},
		},
		{
			name:           "Empty query",
			requestBody:    `{"query": "", "limit": 10}`,
			dbType:         parser.Proton,
			expectedStatus: http.StatusBadRequest,
			setupMock:      func() {},
			validateResp: func(t *testing.T, w *httptest.ResponseRecorder) {
				t.Helper()
				assert.Equal(t, http.StatusBadRequest, w.Code)

				var resp map[string]interface{}

				err := json.Unmarshal(w.Body.Bytes(), &resp)

				require.NoError(t, err)
				assert.Contains(t, resp["message"], "Query string is required")
			},
		},
		{
			name:           "Invalid query",
			requestBody:    `{"query": "invalid query", "limit": 10}`,
			dbType:         parser.Proton,
			expectedStatus: http.StatusBadRequest,
			setupMock:      func() {},
			validateResp: func(t *testing.T, w *httptest.ResponseRecorder) {
				t.Helper()
				assert.Equal(t, http.StatusBadRequest, w.Code)
				var resp map[string]interface{}
				err := json.Unmarshal(w.Body.Bytes(), &resp)
				require.NoError(t, err)
				assert.Contains(t, resp["message"], "failed to parse query")
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := &APIServer{
				dbType:        tt.dbType,
				queryExecutor: mockQueryExecutor,
			}

			tt.setupMock()

			req := httptest.NewRequest(http.MethodPost, "/api/query", strings.NewReader(tt.requestBody))
			req.Header.Set("Content-Type", "application/json")

			w := httptest.NewRecorder()
			s.handleSRQLQuery(w, req)
			tt.validateResp(t, w)
		})
	}
}

// TestCursorFunctions tests the cursor-related functions
func TestCursorFunctions(t *testing.T) {
	// Test decodeCursor
	t.Run("decodeCursor", func(t *testing.T) {
		cursor := "eyJpcCI6IjE5Mi4xNjguMS4xIiwibGFzdF9zZWVuIjoiMjAyNS0wNS0zMFQxMjowMDowMFoifQ=="
		decoded, err := decodeCursor(cursor)
		require.NoError(t, err)

		assert.Equal(t, "192.168.1.1", decoded["ip"])
		assert.Equal(t, "2025-05-30T12:00:00Z", decoded["last_seen"])

		_, err = decodeCursor("invalid-cursor")
		assert.Error(t, err)
	})

	// Test determineOperator
	t.Run("determineOperator", func(t *testing.T) {
		assert.Equal(t, models.LessThan, determineOperator(DirectionNext, models.Descending))
		assert.Equal(t, models.GreaterThan, determineOperator(DirectionPrev, models.Descending))
		assert.Equal(t, models.GreaterThan, determineOperator(DirectionNext, models.Ascending))
		assert.Equal(t, models.LessThan, determineOperator(DirectionPrev, models.Ascending))
	})

	// FIX #2: REMOVED the test for the now-deleted buildEntitySpecificConditions function
	// t.Run("buildEntitySpecificConditions", func(t *testing.T) { ... })

	// Test buildCursorConditions
	t.Run("buildCursorConditions with multi-key sort", func(t *testing.T) {
		query := &models.Query{
			Entity: models.Devices,
			OrderBy: []models.OrderByItem{
				{Field: "last_seen", Direction: models.Descending},
				{Field: "ip", Direction: models.Descending}, // Secondary sort key
			},
		}

		cursorData := map[string]interface{}{
			"ip":        "192.168.1.1",
			"last_seen": "2025-05-30T12:00:00Z",
		}

		conditions := buildCursorConditions(query, cursorData, DirectionNext)

		// Expect one top-level complex AND condition
		require.Len(t, conditions, 1)
		assert.True(t, conditions[0].IsComplex)
		assert.Equal(t, models.And, conditions[0].LogicalOp)

		// This top-level condition should contain the OR groups
		outerOrConditions := conditions[0].Complex
		require.Len(t, outerOrConditions, 2)

		// -- Check the first OR group: (last_seen < 'value') --
		firstGroup := outerOrConditions[0]
		assert.True(t, firstGroup.IsComplex)
		assert.Equal(t, models.Or, firstGroup.LogicalOp)
		require.Len(t, firstGroup.Complex, 1)

		firstGroupCond := firstGroup.Complex[0]
		assert.Equal(t, "last_seen", firstGroupCond.Field)
		assert.Equal(t, models.LessThan, firstGroupCond.Operator)
		assert.Equal(t, "2025-05-30T12:00:00Z", firstGroupCond.Value)

		// -- Check the second OR group: (last_seen = 'value' AND ip < 'value') --
		secondGroup := outerOrConditions[1]
		assert.True(t, secondGroup.IsComplex)
		assert.Equal(t, models.Or, secondGroup.LogicalOp)
		require.Len(t, secondGroup.Complex, 2)

		// last_seen = 'value'
		secondGroupCond1 := secondGroup.Complex[0]
		assert.Equal(t, "last_seen", secondGroupCond1.Field)
		assert.Equal(t, models.Equals, secondGroupCond1.Operator)
		assert.Equal(t, "2025-05-30T12:00:00Z", secondGroupCond1.Value)
		assert.Equal(t, models.And, secondGroupCond1.LogicalOp)

		// ip < 'value'
		secondGroupCond2 := secondGroup.Complex[1]
		assert.Equal(t, "ip", secondGroupCond2.Field)
		assert.Equal(t, models.LessThan, secondGroupCond2.Operator)
		assert.Equal(t, "192.168.1.1", secondGroupCond2.Value)
		assert.Equal(t, models.And, secondGroupCond2.LogicalOp)
	})

	// Test createCursorData
	t.Run("createCursorData", func(t *testing.T) {
		now := time.Now()

		result := map[string]interface{}{
			"ip":        "192.168.1.1",
			"last_seen": now,
		}

		cursorData := createCursorData(result, "last_seen")
		assert.Equal(t, now.Format(time.RFC3339), cursorData["last_seen"])
	})

	// Test addEntityFields
	t.Run("addEntityFields", func(t *testing.T) {
		cursorData := make(map[string]interface{})
		result := map[string]interface{}{"ip": "192.168.1.1"}

		addEntityFields(cursorData, result, models.Devices)
		assert.Equal(t, "192.168.1.1", cursorData["ip"])
	})

	// Test encodeCursor
	t.Run("encodeCursor", func(t *testing.T) {
		cursorData := map[string]interface{}{
			"ip":        "192.168.1.1",
			"last_seen": "2025-05-30T12:00:00Z",
		}
		cursor := encodeCursor(cursorData)
		assert.NotEmpty(t, cursor)
	})

	// Test generateCursors
	t.Run("generateCursors", func(t *testing.T) {
		query := &models.Query{
			Entity:   models.Devices,
			HasLimit: true,
			Limit:    2,
			OrderBy: []models.OrderByItem{
				{Field: "last_seen", Direction: models.Descending},
			},
		}

		results := []map[string]interface{}{
			{"ip": "192.168.1.1", "last_seen": "2025-05-30T12:00:00Z"},
			{"ip": "192.168.1.2", "last_seen": "2025-05-29T12:00:00Z"},
		}

		nextCursor, prevCursor := generateCursors(query, results, parser.Proton)

		assert.NotEmpty(t, nextCursor, "Next cursor should be present on a full page")
		assert.NotEmpty(t, prevCursor)

		// Test with fewer results than limit
		query.Limit = 5
		nextCursor, prevCursor = generateCursors(query, results, parser.Proton)

		assert.Empty(t, nextCursor, "Next cursor should be empty when results are less than limit")
		assert.NotEmpty(t, prevCursor)

		// Test with empty results
		nextCursor, prevCursor = generateCursors(query, []map[string]interface{}{}, parser.Proton)

		assert.Empty(t, nextCursor)
		assert.Empty(t, prevCursor)
	})
}
