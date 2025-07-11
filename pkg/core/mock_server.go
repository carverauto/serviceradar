// Code generated by MockGen. DO NOT EDIT.
// Source: github.com/carverauto/serviceradar/pkg/core (interfaces: NodeService,CoreService,DiscoveryService)
//
// Generated by this command:
//
//	mockgen -destination=mock_server.go -package=core github.com/carverauto/serviceradar/pkg/core NodeService,CoreService,DiscoveryService
//

// Package core is a generated GoMock package.
package core

import (
	context "context"
	json "encoding/json"
	reflect "reflect"
	time "time"

	api "github.com/carverauto/serviceradar/pkg/core/api"
	metrics "github.com/carverauto/serviceradar/pkg/metrics"
	proto "github.com/carverauto/serviceradar/proto"
	gomock "go.uber.org/mock/gomock"
)

// MockNodeService is a mock of NodeService interface.
type MockNodeService struct {
	ctrl     *gomock.Controller
	recorder *MockNodeServiceMockRecorder
	isgomock struct{}
}

// MockNodeServiceMockRecorder is the mock recorder for MockNodeService.
type MockNodeServiceMockRecorder struct {
	mock *MockNodeService
}

// NewMockNodeService creates a new mock instance.
func NewMockNodeService(ctrl *gomock.Controller) *MockNodeService {
	mock := &MockNodeService{ctrl: ctrl}
	mock.recorder = &MockNodeServiceMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockNodeService) EXPECT() *MockNodeServiceMockRecorder {
	return m.recorder
}

// CheckNodeHealth mocks base method.
func (m *MockNodeService) CheckNodeHealth(nodeID string) (bool, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "CheckNodeHealth", nodeID)
	ret0, _ := ret[0].(bool)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// CheckNodeHealth indicates an expected call of CheckNodeHealth.
func (mr *MockNodeServiceMockRecorder) CheckNodeHealth(nodeID any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "CheckNodeHealth", reflect.TypeOf((*MockNodeService)(nil).CheckNodeHealth), nodeID)
}

// GetNodeHistory mocks base method.
func (m *MockNodeService) GetNodeHistory(nodeID string, limit int) ([]api.PollerHistoryPoint, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeHistory", nodeID, limit)
	ret0, _ := ret[0].([]api.PollerHistoryPoint)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeHistory indicates an expected call of GetNodeHistory.
func (mr *MockNodeServiceMockRecorder) GetNodeHistory(nodeID, limit any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeHistory", reflect.TypeOf((*MockNodeService)(nil).GetNodeHistory), nodeID, limit)
}

// GetNodeStatus mocks base method.
func (m *MockNodeService) GetNodeStatus(nodeID string) (*api.PollerStatus, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetNodeStatus", nodeID)
	ret0, _ := ret[0].(*api.PollerStatus)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetNodeStatus indicates an expected call of GetNodeStatus.
func (mr *MockNodeServiceMockRecorder) GetNodeStatus(nodeID any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetNodeStatus", reflect.TypeOf((*MockNodeService)(nil).GetNodeStatus), nodeID)
}

// UpdateNodeStatus mocks base method.
func (m *MockNodeService) UpdateNodeStatus(nodeID string, status *api.PollerStatus) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "UpdateNodeStatus", nodeID, status)
	ret0, _ := ret[0].(error)
	return ret0
}

// UpdateNodeStatus indicates an expected call of UpdateNodeStatus.
func (mr *MockNodeServiceMockRecorder) UpdateNodeStatus(nodeID, status any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "UpdateNodeStatus", reflect.TypeOf((*MockNodeService)(nil).UpdateNodeStatus), nodeID, status)
}

// MockCoreService is a mock of CoreService interface.
type MockCoreService struct {
	ctrl     *gomock.Controller
	recorder *MockCoreServiceMockRecorder
	isgomock struct{}
}

// MockCoreServiceMockRecorder is the mock recorder for MockCoreService.
type MockCoreServiceMockRecorder struct {
	mock *MockCoreService
}

// NewMockCoreService creates a new mock instance.
func NewMockCoreService(ctrl *gomock.Controller) *MockCoreService {
	mock := &MockCoreService{ctrl: ctrl}
	mock.recorder = &MockCoreServiceMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockCoreService) EXPECT() *MockCoreServiceMockRecorder {
	return m.recorder
}

// GetMetricsManager mocks base method.
func (m *MockCoreService) GetMetricsManager() metrics.MetricCollector {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetMetricsManager")
	ret0, _ := ret[0].(metrics.MetricCollector)
	return ret0
}

// GetMetricsManager indicates an expected call of GetMetricsManager.
func (mr *MockCoreServiceMockRecorder) GetMetricsManager() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetMetricsManager", reflect.TypeOf((*MockCoreService)(nil).GetMetricsManager))
}

// ReportStatus mocks base method.
func (m *MockCoreService) ReportStatus(ctx context.Context, nodeID string, status *api.PollerStatus) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "ReportStatus", ctx, nodeID, status)
	ret0, _ := ret[0].(error)
	return ret0
}

// ReportStatus indicates an expected call of ReportStatus.
func (mr *MockCoreServiceMockRecorder) ReportStatus(ctx, nodeID, status any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "ReportStatus", reflect.TypeOf((*MockCoreService)(nil).ReportStatus), ctx, nodeID, status)
}

// Start mocks base method.
func (m *MockCoreService) Start(ctx context.Context) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Start", ctx)
	ret0, _ := ret[0].(error)
	return ret0
}

// Start indicates an expected call of Start.
func (mr *MockCoreServiceMockRecorder) Start(ctx any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Start", reflect.TypeOf((*MockCoreService)(nil).Start), ctx)
}

// Stop mocks base method.
func (m *MockCoreService) Stop(ctx context.Context) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Stop", ctx)
	ret0, _ := ret[0].(error)
	return ret0
}

// Stop indicates an expected call of Stop.
func (mr *MockCoreServiceMockRecorder) Stop(ctx any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Stop", reflect.TypeOf((*MockCoreService)(nil).Stop), ctx)
}

// MockDiscoveryService is a mock of DiscoveryService interface.
type MockDiscoveryService struct {
	ctrl     *gomock.Controller
	recorder *MockDiscoveryServiceMockRecorder
	isgomock struct{}
}

// MockDiscoveryServiceMockRecorder is the mock recorder for MockDiscoveryService.
type MockDiscoveryServiceMockRecorder struct {
	mock *MockDiscoveryService
}

// NewMockDiscoveryService creates a new mock instance.
func NewMockDiscoveryService(ctrl *gomock.Controller) *MockDiscoveryService {
	mock := &MockDiscoveryService{ctrl: ctrl}
	mock.recorder = &MockDiscoveryServiceMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockDiscoveryService) EXPECT() *MockDiscoveryServiceMockRecorder {
	return m.recorder
}

// ProcessSNMPDiscoveryResults mocks base method.
func (m *MockDiscoveryService) ProcessSNMPDiscoveryResults(ctx context.Context, reportingPollerID, partition string, svc *proto.ServiceStatus, details json.RawMessage, timestamp time.Time) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "ProcessSNMPDiscoveryResults", ctx, reportingPollerID, partition, svc, details, timestamp)
	ret0, _ := ret[0].(error)
	return ret0
}

// ProcessSNMPDiscoveryResults indicates an expected call of ProcessSNMPDiscoveryResults.
func (mr *MockDiscoveryServiceMockRecorder) ProcessSNMPDiscoveryResults(ctx, reportingPollerID, partition, svc, details, timestamp any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "ProcessSNMPDiscoveryResults", reflect.TypeOf((*MockDiscoveryService)(nil).ProcessSNMPDiscoveryResults), ctx, reportingPollerID, partition, svc, details, timestamp)
}

// ProcessSyncResults mocks base method.
func (m *MockDiscoveryService) ProcessSyncResults(ctx context.Context, reportingPollerID, partition string, svc *proto.ServiceStatus, details json.RawMessage, timestamp time.Time) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "ProcessSyncResults", ctx, reportingPollerID, partition, svc, details, timestamp)
	ret0, _ := ret[0].(error)
	return ret0
}

// ProcessSyncResults indicates an expected call of ProcessSyncResults.
func (mr *MockDiscoveryServiceMockRecorder) ProcessSyncResults(ctx, reportingPollerID, partition, svc, details, timestamp any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "ProcessSyncResults", reflect.TypeOf((*MockDiscoveryService)(nil).ProcessSyncResults), ctx, reportingPollerID, partition, svc, details, timestamp)
}
