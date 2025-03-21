// Code generated by MockGen. DO NOT EDIT.
// Source: github.com/carverauto/serviceradar/pkg/agent (interfaces: Service,SweepStatusProvider)
//
// Generated by this command:
//
//	mockgen -destination=mock_agent.go -package=agent github.com/carverauto/serviceradar/pkg/agent Service,SweepStatusProvider
//

// Package agent is a generated GoMock package.
package agent

import (
	context "context"
	reflect "reflect"

	proto "github.com/carverauto/serviceradar/proto"
	gomock "go.uber.org/mock/gomock"
)

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

// Name mocks base method.
func (m *MockService) Name() string {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Name")
	ret0, _ := ret[0].(string)
	return ret0
}

// Name indicates an expected call of Name.
func (mr *MockServiceMockRecorder) Name() *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Name", reflect.TypeOf((*MockService)(nil).Name))
}

// Start mocks base method.
func (m *MockService) Start(arg0 context.Context) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Start", arg0)
	ret0, _ := ret[0].(error)
	return ret0
}

// Start indicates an expected call of Start.
func (mr *MockServiceMockRecorder) Start(arg0 any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Start", reflect.TypeOf((*MockService)(nil).Start), arg0)
}

// Stop mocks base method.
func (m *MockService) Stop(ctx context.Context) error {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Stop", ctx)
	ret0, _ := ret[0].(error)
	return ret0
}

// Stop indicates an expected call of Stop.
func (mr *MockServiceMockRecorder) Stop(ctx any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Stop", reflect.TypeOf((*MockService)(nil).Stop), ctx)
}

// MockSweepStatusProvider is a mock of SweepStatusProvider interface.
type MockSweepStatusProvider struct {
	ctrl     *gomock.Controller
	recorder *MockSweepStatusProviderMockRecorder
	isgomock struct{}
}

// MockSweepStatusProviderMockRecorder is the mock recorder for MockSweepStatusProvider.
type MockSweepStatusProviderMockRecorder struct {
	mock *MockSweepStatusProvider
}

// NewMockSweepStatusProvider creates a new mock instance.
func NewMockSweepStatusProvider(ctrl *gomock.Controller) *MockSweepStatusProvider {
	mock := &MockSweepStatusProvider{ctrl: ctrl}
	mock.recorder = &MockSweepStatusProviderMockRecorder{mock}
	return mock
}

// EXPECT returns an object that allows the caller to indicate expected use.
func (m *MockSweepStatusProvider) EXPECT() *MockSweepStatusProviderMockRecorder {
	return m.recorder
}

// GetStatus mocks base method.
func (m *MockSweepStatusProvider) GetStatus(arg0 context.Context) (*proto.StatusResponse, error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "GetStatus", arg0)
	ret0, _ := ret[0].(*proto.StatusResponse)
	ret1, _ := ret[1].(error)
	return ret0, ret1
}

// GetStatus indicates an expected call of GetStatus.
func (mr *MockSweepStatusProviderMockRecorder) GetStatus(arg0 any) *gomock.Call {
	mr.mock.ctrl.T.Helper()
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "GetStatus", reflect.TypeOf((*MockSweepStatusProvider)(nil).GetStatus), arg0)
}
