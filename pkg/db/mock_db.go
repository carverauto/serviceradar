// Code generated by MockGen. DO NOT EDIT.
// Source: github.com/carverauto/serviceradar/pkg/db (interfaces: Row,Result,Rows,Transaction,Service)
//
// Generated by this command:
//
//	mockgen -destination=mock_db.go -package=db github.com/carverauto/serviceradar/pkg/db Row,Result,Rows,Transaction,Service
//

// Package db is a generated GoMock package.
package db

import (
	reflect "reflect"
	time "time"

	models "github.com/carverauto/serviceradar/pkg/models"
	gomock "go.uber.org/mock/gomock"
)

// MockRow is a mock of Row interface.
type MockRow struct {
	ctrl     *gomock.Controller
	recorder *MockRowMockRecorder
	isgomock struct{}
}

// MockRowMockRecorder is the mock recorder for MockRow.
type MockRowMockRecorder struct {
	mock *MockRow
}

// NewMockRow creates a new mock instance.
func NewMockRow(ctrl *gomock.Controller) *MockRow {
	mock := &MockRow{ctrl: ctrl}
	mock.recorder = &MockRowMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockRow) EXPECT() *MockRowMockRecorder {
	return m.recorder
}

// Scan mocks base method.
func (m *MockRow) Scan(dest ...any) error {
	m.ctrl.T.Helper()
	varargs := []any{}
	for _, a := range dest {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Scan", varargs...)
	ret0, _ := ret[0].(error)
	return ret0
}

// Scan indicates an expected call of Scan.
func (mr *MockRowMockRecorder) Scan(dest ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Scan", reflect.TypeOf((*MockRow)(nil).Scan), dest...)
}

// MockResult is a mock of Result interface.
type MockResult struct {
	ctrl     *gomock.Controller
	recorder *MockResultMockRecorder
	isgomock struct{}
}

// MockResultMockRecorder is the mock recorder for MockResult.
type MockResultMockRecorder struct {
	mock *MockResult
}

// NewMockResult creates a new mock instance.
func NewMockResult(ctrl *gomock.Controller) *MockResult {
	mock := &MockResult{ctrl: ctrl}
	mock.recorder = &MockResultMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockResult) EXPECT() *MockResultMockRecorder {
	return m.recorder
}

// LastInsertId mocks base method.
func (m *MockResult) LastInsertId() (int64, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "LastInsertId")
	ret0, _ := ret[0].(int64)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// LastInsertId indicates an expected call of LastInsertId.
func (mr *MockResultMockRecorder) LastInsertId() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "LastInsertId", reflect.TypeOf((*MockResult)(nil).LastInsertId))
}

// RowsAffected mocks base method.
func (m *MockResult) RowsAffected() (int64, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "RowsAffected")
	ret0, _ := ret[0].(int64)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// RowsAffected indicates an expected call of RowsAffected.
func (mr *MockResultMockRecorder) RowsAffected() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "RowsAffected", reflect.TypeOf((*MockResult)(nil).RowsAffected))
}

// MockRows is a mock of Rows interface.
type MockRows struct {
	ctrl     *gomock.Controller
	recorder *MockRowsMockRecorder
	isgomock struct{}
}

// MockRowsMockRecorder is the mock recorder for MockRows.
type MockRowsMockRecorder struct {
	mock *MockRows
}

// NewMockRows creates a new mock instance.
func NewMockRows(ctrl *gomock.Controller) *MockRows {
	mock := &MockRows{ctrl: ctrl}
	mock.recorder = &MockRowsMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockRows) EXPECT() *MockRowsMockRecorder {
	return m.recorder
}

// Close mocks base method.
func (m *MockRows) Close() error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Close")
	ret0, _ := ret[0].(error)
	return ret0
}

// Close indicates an expected call of Close.
func (mr *MockRowsMockRecorder) Close() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Close", reflect.TypeOf((*MockRows)(nil).Close))
}

// Err mocks base method.
func (m *MockRows) Err() error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Err")
	ret0, _ := ret[0].(error)
	return ret0
}

// Err indicates an expected call of Err.
func (mr *MockRowsMockRecorder) Err() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Err", reflect.TypeOf((*MockRows)(nil).Err))
}

// Next mocks base method.
func (m *MockRows) Next() bool {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Next")
	ret0, _ := ret[0].(bool)
	return ret0
}

// Next indicates an expected call of Next.
func (mr *MockRowsMockRecorder) Next() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Next", reflect.TypeOf((*MockRows)(nil).Next))
}

// Scan mocks base method.
func (m *MockRows) Scan(dest ...any) error {
	m.ctrl.T.Helper()
	varargs := []any{}
	for _, a := range dest {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Scan", varargs...)
	ret0, _ := ret[0].(error)
	return ret0
}

// Scan indicates an expected call of Scan.
func (mr *MockRowsMockRecorder) Scan(dest ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Scan", reflect.TypeOf((*MockRows)(nil).Scan), dest...)
}

// MockTransaction is a mock of Transaction interface.
type MockTransaction struct {
	ctrl     *gomock.Controller
	recorder *MockTransactionMockRecorder
	isgomock struct{}
}

// MockTransactionMockRecorder is the mock recorder for MockTransaction.
type MockTransactionMockRecorder struct {
	mock *MockTransaction
}

// NewMockTransaction creates a new mock instance.
func NewMockTransaction(ctrl *gomock.Controller) *MockTransaction {
	mock := &MockTransaction{ctrl: ctrl}
	mock.recorder = &MockTransactionMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockTransaction) EXPECT() *MockTransactionMockRecorder {
	return m.recorder
}

// Commit mocks base method.
func (m *MockTransaction) Commit() error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Commit")
	ret0, _ := ret[0].(error)
	return ret0
}

// Commit indicates an expected call of Commit.
func (mr *MockTransactionMockRecorder) Commit() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Commit", reflect.TypeOf((*MockTransaction)(nil).Commit))
}

// Exec mocks base method.
func (m *MockTransaction) Exec(query string, args ...any) (Result, error) {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Exec", varargs...)
	ret0, _ := ret[0].(Result)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// Exec indicates an expected call of Exec.
func (mr *MockTransactionMockRecorder) Exec(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Exec", reflect.TypeOf((*MockTransaction)(nil).Exec), varargs...)
}

// Query mocks base method.
func (m *MockTransaction) Query(query string, args ...any) (Rows, error) {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Query", varargs...)
	ret0, _ := ret[0].(Rows)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// Query indicates an expected call of Query.
func (mr *MockTransactionMockRecorder) Query(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Query", reflect.TypeOf((*MockTransaction)(nil).Query), varargs...)
}

// QueryRow mocks base method.
func (m *MockTransaction) QueryRow(query string, args ...any) Row {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "QueryRow", varargs...)
	ret0, _ := ret[0].(Row)
	return ret0
}

// QueryRow indicates an expected call of QueryRow.
func (mr *MockTransactionMockRecorder) QueryRow(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "QueryRow", reflect.TypeOf((*MockTransaction)(nil).QueryRow), varargs...)
}

// Rollback mocks base method.
func (m *MockTransaction) Rollback() error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Rollback")
	ret0, _ := ret[0].(error)
	return ret0
}

// Rollback indicates an expected call of Rollback.
func (mr *MockTransactionMockRecorder) Rollback() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Rollback", reflect.TypeOf((*MockTransaction)(nil).Rollback))
}

// MockService is a mock of Service interface.
type MockService struct {
	ctrl     *gomock.Controller
	recorder *MockServiceMockRecorder
	isgomock struct{}
}

// MockServiceMockRecorder is the mock recorder for MockService.
type MockServiceMockRecorder struct {
	mock *MockService
}

// NewMockService creates a new mock instance.
func NewMockService(ctrl *gomock.Controller) *MockService {
	mock := &MockService{ctrl: ctrl}
	mock.recorder = &MockServiceMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockService) EXPECT() *MockServiceMockRecorder {
	return m.recorder
}

// Begin mocks base method.
func (m *MockService) Begin() (Transaction, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Begin")
	ret0, _ := ret[0].(Transaction)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// Begin indicates an expected call of Begin.
func (mr *MockServiceMockRecorder) Begin() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Begin", reflect.TypeOf((*MockService)(nil).Begin))
}

// CleanOldData mocks base method.
func (m *MockService) CleanOldData(retentionPeriod time.Duration) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "CleanOldData", retentionPeriod)
	ret0, _ := ret[0].(error)
	return ret0
}

// CleanOldData indicates an expected call of CleanOldData.
func (mr *MockServiceMockRecorder) CleanOldData(retentionPeriod any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "CleanOldData", reflect.TypeOf((*MockService)(nil).CleanOldData), retentionPeriod)
}

// Close mocks base method.
func (m *MockService) Close() error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Close")
	ret0, _ := ret[0].(error)
	return ret0
}

// Close indicates an expected call of Close.
func (mr *MockServiceMockRecorder) Close() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Close", reflect.TypeOf((*MockService)(nil).Close))
}

// Exec mocks base method.
func (m *MockService) Exec(query string, args ...any) (Result, error) {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Exec", varargs...)
	ret0, _ := ret[0].(Result)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// Exec indicates an expected call of Exec.
func (mr *MockServiceMockRecorder) Exec(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Exec", reflect.TypeOf((*MockService)(nil).Exec), varargs...)
}

// GetMetrics mocks base method.
func (m *MockService) GetMetrics(nodeID, metricName string, start, end time.Time) ([]TimeseriesMetric, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetMetrics", nodeID, metricName, start, end)
	ret0, _ := ret[0].([]TimeseriesMetric)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetMetrics indicates an expected call of GetMetrics.
func (mr *MockServiceMockRecorder) GetMetrics(nodeID, metricName, start, end any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetMetrics", reflect.TypeOf((*MockService)(nil).GetMetrics), nodeID, metricName, start, end)
}

// GetMetricsByType mocks base method.
func (m *MockService) GetMetricsByType(nodeID, metricType string, start, end time.Time) ([]TimeseriesMetric, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetMetricsByType", nodeID, metricType, start, end)
	ret0, _ := ret[0].([]TimeseriesMetric)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetMetricsByType indicates an expected call of GetMetricsByType.
func (mr *MockServiceMockRecorder) GetMetricsByType(nodeID, metricType, start, end any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetMetricsByType", reflect.TypeOf((*MockService)(nil).GetMetricsByType), nodeID, metricType, start, end)
}

// GetNodeHistory mocks base method.
func (m *MockService) GetNodeHistory(nodeID string) ([]NodeStatus, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeHistory", nodeID)
	ret0, _ := ret[0].([]NodeStatus)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeHistory indicates an expected call of GetNodeHistory.
func (mr *MockServiceMockRecorder) GetNodeHistory(nodeID any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeHistory", reflect.TypeOf((*MockService)(nil).GetNodeHistory), nodeID)
}

// GetNodeHistoryPoints mocks base method.
func (m *MockService) GetNodeHistoryPoints(nodeID string, limit int) ([]NodeHistoryPoint, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeHistoryPoints", nodeID, limit)
	ret0, _ := ret[0].([]NodeHistoryPoint)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeHistoryPoints indicates an expected call of GetNodeHistoryPoints.
func (mr *MockServiceMockRecorder) GetNodeHistoryPoints(nodeID, limit any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeHistoryPoints", reflect.TypeOf((*MockService)(nil).GetNodeHistoryPoints), nodeID, limit)
}

// GetNodeServices mocks base method.
func (m *MockService) GetNodeServices(nodeID string) ([]ServiceStatus, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeServices", nodeID)
	ret0, _ := ret[0].([]ServiceStatus)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeServices indicates an expected call of GetNodeServices.
func (mr *MockServiceMockRecorder) GetNodeServices(nodeID any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeServices", reflect.TypeOf((*MockService)(nil).GetNodeServices), nodeID)
}

// GetNodeStatus mocks base method.
func (m *MockService) GetNodeStatus(nodeID string) (*NodeStatus, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeStatus", nodeID)
	ret0, _ := ret[0].(*NodeStatus)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeStatus indicates an expected call of GetNodeStatus.
func (mr *MockServiceMockRecorder) GetNodeStatus(nodeID any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeStatus", reflect.TypeOf((*MockService)(nil).GetNodeStatus), nodeID)
}

// GetServiceHistory mocks base method.
func (m *MockService) GetServiceHistory(nodeID, serviceName string, limit int) ([]ServiceStatus, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetServiceHistory", nodeID, serviceName, limit)
	ret0, _ := ret[0].([]ServiceStatus)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetServiceHistory indicates an expected call of GetServiceHistory.
func (mr *MockServiceMockRecorder) GetServiceHistory(nodeID, serviceName, limit any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetServiceHistory", reflect.TypeOf((*MockService)(nil).GetServiceHistory), nodeID, serviceName, limit)
}

// GetUserByID mocks base method.
func (m *MockService) GetUserByID(id string) (*models.User, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetUserByID", id)
	ret0, _ := ret[0].(*models.User)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetUserByID indicates an expected call of GetUserByID.
func (mr *MockServiceMockRecorder) GetUserByID(id any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetUserByID", reflect.TypeOf((*MockService)(nil).GetUserByID), id)
}

// IsNodeOffline mocks base method.
func (m *MockService) IsNodeOffline(nodeID string, threshold time.Duration) (bool, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "IsNodeOffline", nodeID, threshold)
	ret0, _ := ret[0].(bool)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// IsNodeOffline indicates an expected call of IsNodeOffline.
func (mr *MockServiceMockRecorder) IsNodeOffline(nodeID, threshold any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "IsNodeOffline", reflect.TypeOf((*MockService)(nil).IsNodeOffline), nodeID, threshold)
}

// Query mocks base method.
func (m *MockService) Query(query string, args ...any) (Rows, error) {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "Query", varargs...)
	ret0, _ := ret[0].(Rows)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// Query indicates an expected call of Query.
func (mr *MockServiceMockRecorder) Query(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Query", reflect.TypeOf((*MockService)(nil).Query), varargs...)
}

// QueryRow mocks base method.
func (m *MockService) QueryRow(query string, args ...any) Row {
	m.ctrl.T.Helper()
	varargs := []any{query}
	for _, a := range args {
		varargs = append(varargs, a)
	}
	ret := m.ctrl.Call(m, "QueryRow", varargs...)
	ret0, _ := ret[0].(Row)
	return ret0
}

// QueryRow indicates an expected call of QueryRow.
func (mr *MockServiceMockRecorder) QueryRow(query any, args ...any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	varargs := append([]any{query}, args...)
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "QueryRow", reflect.TypeOf((*MockService)(nil).QueryRow), varargs...)
}

// StoreMetric mocks base method.
func (m *MockService) StoreMetric(nodeID string, metric *TimeseriesMetric) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "StoreMetric", nodeID, metric)
	ret0, _ := ret[0].(error)
	return ret0
}

// StoreMetric indicates an expected call of StoreMetric.
func (mr *MockServiceMockRecorder) StoreMetric(nodeID, metric any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "StoreMetric", reflect.TypeOf((*MockService)(nil).StoreMetric), nodeID, metric)
}

// StoreRperfMetrics mocks base method.
func (m *MockService) StoreRperfMetrics(nodeID, serviceName, message string, timestamp time.Time) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "StoreRperfMetrics", nodeID, serviceName, message, timestamp)
	ret0, _ := ret[0].(error)
	return ret0
}

// StoreRperfMetrics indicates an expected call of StoreRperfMetrics.
func (mr *MockServiceMockRecorder) StoreRperfMetrics(nodeID, serviceName, message, timestamp any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "StoreRperfMetrics", reflect.TypeOf((*MockService)(nil).StoreRperfMetrics), nodeID, serviceName, message, timestamp)
}

// StoreUser mocks base method.
func (m *MockService) StoreUser(user *models.User) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "StoreUser", user)
	ret0, _ := ret[0].(error)
	return ret0
}

// StoreUser indicates an expected call of StoreUser.
func (mr *MockServiceMockRecorder) StoreUser(user any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "StoreUser", reflect.TypeOf((*MockService)(nil).StoreUser), user)
}

// UpdateNodeStatus mocks base method.
func (m *MockService) UpdateNodeStatus(status *NodeStatus) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "UpdateNodeStatus", status)
	ret0, _ := ret[0].(error)
	return ret0
}

// UpdateNodeStatus indicates an expected call of UpdateNodeStatus.
func (mr *MockServiceMockRecorder) UpdateNodeStatus(status any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "UpdateNodeStatus", reflect.TypeOf((*MockService)(nil).UpdateNodeStatus), status)
}

// UpdateServiceStatus mocks base method.
func (m *MockService) UpdateServiceStatus(status *ServiceStatus) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "UpdateServiceStatus", status)
	ret0, _ := ret[0].(error)
	return ret0
}

// UpdateServiceStatus indicates an expected call of UpdateServiceStatus.
func (mr *MockServiceMockRecorder) UpdateServiceStatus(status any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "UpdateServiceStatus", reflect.TypeOf((*MockService)(nil).UpdateServiceStatus), status)
}
