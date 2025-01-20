package scan

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

var (
	errTCPScanFailed  = fmt.Errorf("TCP scan failed")
	errICMPScanFailed = fmt.Errorf("ICMP scan failed")
)

// TestCombinedScanner_ScanBasic tests basic scanner functionality.
func TestCombinedScanner_ScanBasic(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockTCP := NewMockScanner(ctrl)
	mockICMP := NewMockScanner(ctrl)

	// Test empty targets
	scanner := &CombinedScanner{
		tcpScanner:  mockTCP,
		icmpScanner: mockICMP,
		done:        make(chan struct{}),
	}

	ctx := context.Background()
	results, err := scanner.Scan(ctx, []models.Target{})

	require.NoError(t, err)
	require.NotNil(t, results)

	count := 0
	for range results {
		count++
	}

	assert.Equal(t, 0, count)
}

// TestCombinedScanner_ScanMixed tests scanning with mixed target types.
func TestCombinedScanner_ScanMixed(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockTCP := NewMockScanner(ctrl)
	mockICMP := NewMockScanner(ctrl)

	targets := []models.Target{
		{Host: "192.168.1.1", Port: 80, Mode: models.ModeTCP},
		{Host: "192.168.1.2", Mode: models.ModeICMP},
	}

	tcpResults := make(chan models.Result, 1)
	icmpResults := make(chan models.Result, 1)

	// Define expected results
	tcpResult := models.Result{
		Target: models.Target{
			Host: "192.168.1.1",
			Port: 80,
			Mode: models.ModeTCP,
		},
		Available: true,
	}

	icmpResult := models.Result{
		Target: models.Target{
			Host: "192.168.1.2",
			Mode: models.ModeICMP,
		},
		Available: true,
	}

	// Send results and close channels
	go func() {
		tcpResults <- tcpResult
		close(tcpResults)
	}()

	go func() {
		icmpResults <- icmpResult
		close(icmpResults)
	}()

	mockTCP.EXPECT().
		Scan(gomock.Any(), matchTargets(models.ModeTCP)).
		Return(tcpResults, nil)

	mockICMP.EXPECT().
		Scan(gomock.Any(), matchTargets(models.ModeICMP)).
		Return(icmpResults, nil)

	mockTCP.EXPECT().Stop().Return(nil).AnyTimes()
	mockICMP.EXPECT().Stop().Return(nil).AnyTimes()

	scanner := &CombinedScanner{
		tcpScanner:  mockTCP,
		icmpScanner: mockICMP,
		done:        make(chan struct{}),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)
	require.NotNil(t, results)

	gotResults := make([]models.Result, 0, len(targets)) // Pre-allocate with capacity
	for result := range results {
		gotResults = append(gotResults, result)
	}

	require.Len(t, gotResults, 2)
	assertResultsMatch(t, []models.Result{tcpResult, icmpResult}, gotResults)
}

// TestCombinedScanner_ScanErrors tests error handling.
func TestCombinedScanner_ScanErrors(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name       string
		targets    []models.Target
		setupMocks func(mockTCP, mockICMP *MockScanner)
		wantErr    bool
		wantErrStr string
	}{
		{
			name: "TCP scanner error",
			targets: []models.Target{
				{Host: "192.168.1.1", Port: 80, Mode: models.ModeTCP},
			},
			setupMocks: func(mockTCP, mockICMP *MockScanner) {
				mockTCP.EXPECT().
					Scan(gomock.Any(), gomock.Any()).
					Return(nil, errTCPScanFailed)
				mockTCP.EXPECT().Stop().Return(nil).AnyTimes()
				mockICMP.EXPECT().Stop().Return(nil).AnyTimes()
			},
			wantErr:    true,
			wantErrStr: "TCP scan error: TCP scan failed",
		},
		{
			name: "ICMP scanner error",
			targets: []models.Target{
				{Host: "192.168.1.2", Mode: models.ModeICMP},
			},
			setupMocks: func(mockTCP, mockICMP *MockScanner) {
				mockICMP.EXPECT().
					Scan(gomock.Any(), gomock.Any()).
					Return(nil, errICMPScanFailed)
				mockTCP.EXPECT().Stop().Return(nil).AnyTimes()
				mockICMP.EXPECT().Stop().Return(nil).AnyTimes()
			},
			wantErr:    true,
			wantErrStr: "ICMP scan error: ICMP scan failed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockTCP := NewMockScanner(ctrl)
			mockICMP := NewMockScanner(ctrl)

			tt.setupMocks(mockTCP, mockICMP)

			scanner := &CombinedScanner{
				tcpScanner:  mockTCP,
				icmpScanner: mockICMP,
				done:        make(chan struct{}),
			}

			_, err := scanner.Scan(context.Background(), tt.targets)

			if tt.wantErr {
				require.Error(t, err)
				assert.Equal(t, tt.wantErrStr, err.Error())

				return
			}

			require.NoError(t, err)
		})
	}
}

// Helper functions

func matchTargets(mode models.SweepMode) gomock.Matcher {
	return targetModeMatcher{mode: mode}
}

type targetModeMatcher struct {
	mode models.SweepMode
}

func (m targetModeMatcher) Matches(x interface{}) bool {
	targets, ok := x.([]models.Target)
	if !ok {
		return false
	}

	for _, t := range targets {
		if t.Mode != m.mode {
			return false
		}
	}

	return true
}

func (m targetModeMatcher) String() string {
	return fmt.Sprintf("targets with mode %s", m.mode)
}

func assertResultsMatch(t *testing.T, expected, got []models.Result) {
	t.Helper()
	require.Equal(t, len(expected), len(got))

	for i := range expected {
		assert.Equal(t, expected[i].Target, got[i].Target)
		assert.Equal(t, expected[i].Available, got[i].Available)
	}
}
