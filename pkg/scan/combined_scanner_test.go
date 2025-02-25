package scan

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

var (
	errTCPScanFailed = fmt.Errorf("TCP scan failed")
)

func TestCombinedScanner_Scan_Mock(t *testing.T) {
	t.Log("Starting test")
	ctrl := gomock.NewController(t)

	defer ctrl.Finish()

	mockTCP := NewMockScanner(ctrl)
	mockICMP := NewMockScanner(ctrl)

	scanner := &CombinedScanner{
		tcpScanner:  mockTCP,
		icmpScanner: mockICMP,
		done:        make(chan struct{}),
	}

	// Create a context with timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Ensure scanner cleanup.
	defer cleanupScanner(t, scanner)

	targets := []models.Target{
		{Host: "127.0.0.1", Port: 22, Mode: models.ModeTCP},
	}

	tcpResults := make(chan models.Result, 1)
	mockComplete := make(chan struct{})

	// Set up mock expectations in a helper.
	setupMockExpectations(t, mockTCP, mockICMP, tcpResults, mockComplete)

	t.Log("Starting scan")

	results, err := scanner.Scan(ctx, targets)

	require.NoError(t, err)
	require.NotNil(t, results)

	t.Log("Scan started successfully")

	// Collect results in a goroutine.
	var gotResults []models.Result

	resultsDone := make(chan struct{})

	go func() {
		t.Log("Starting to collect results")

		defer close(resultsDone)

		for result := range results {
			t.Logf("Received result: %+v", result)
			gotResults = append(gotResults, result)
		}

		t.Log("Finished collecting results")
	}()

	// Wait for results, a mock-completion signal, or a timeout.
	select {
	case <-resultsDone:
		require.Len(t, gotResults, len(targets), "Expected one result")
		require.True(t, gotResults[0].Available, "Expected target to be available")
		t.Log("Test completed successfully")
	case <-mockComplete:
		// Allow a grace period for the results channel to close.
		select {
		case <-resultsDone:
			require.Len(t, gotResults, len(targets), "Expected one result")
			require.True(t, gotResults[0].Available, "Expected target to be available")
			t.Log("Test completed successfully after grace period")
		case <-time.After(100 * time.Millisecond):
			t.Fatal("Test timed out waiting for results channel to close")
		}
	case <-ctx.Done():
		t.Fatal("Test timed out waiting for results")
	}
}

func setupMockExpectations(t *testing.T,
	mockTCP, mockICMP *MockScanner, tcpResults chan models.Result, mockComplete chan struct{}) {
	t.Helper()
	mockTCP.EXPECT().
		Scan(gomock.Any(), gomock.Any()).
		DoAndReturn(func(ctx context.Context, targets []models.Target) (<-chan models.Result, error) {
			t.Log("Mock TCP scan called")
			go func() {
				defer close(tcpResults)
				select {
				case <-ctx.Done():
					return
				case tcpResults <- models.Result{
					Target:    targets[0],
					Available: true,
					RespTime:  10 * time.Millisecond,
				}:
					t.Log("TCP results sent and channel closed")
					close(mockComplete)
				}
			}()
			return tcpResults, nil
		}).Times(1)

	mockTCP.EXPECT().
		Stop(gomock.Any()).
		DoAndReturn(func(context.Context) error {
			t.Log("Mock TCP Stop called")
			return nil
		}).AnyTimes()

	mockICMP.EXPECT().
		Stop(gomock.Any()).
		DoAndReturn(func(context.Context) error {
			t.Log("Mock ICMP Stop called")
			return nil
		}).AnyTimes()
}

func cleanupScanner(t *testing.T, scanner *CombinedScanner) {
	t.Helper()
	t.Log("Running deferred cleanup")

	stopCtx, stopCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stopCancel()

	if err := scanner.Stop(stopCtx); err != nil {
		t.Logf("Warning: error stopping scanner: %v", err)
	}
}

func TestNewCombinedScanner_ICMPError(t *testing.T) {
	// Simulate an error by passing invalid parameters
	scanner := NewCombinedScanner(1*time.Second, 1, 0, 1, 1, 1)
	require.NotNil(t, scanner)
	require.Nil(t, scanner.icmpScanner, "ICMP scanner should be nil due to error")
}

func TestCombinedScanner_Scan_MixedTargets(t *testing.T) {
	t.Parallel() // Allow parallel test execution

	ctrl, ctx := gomock.WithContext(context.Background(), t)
	defer ctrl.Finish()

	// Create context with timeout
	ctx, cancel := context.WithTimeout(ctx, 1*time.Second)
	defer cancel()

	mockTCP := NewMockScanner(ctrl)
	mockICMP := NewMockScanner(ctrl)

	targets := []models.Target{
		{Host: "192.168.1.1", Port: 80, Mode: models.ModeTCP},
		{Host: "192.168.1.2", Mode: models.ModeICMP},
	}

	tcpResults := make(chan models.Result, 1)
	icmpResults := make(chan models.Result, 1)

	// Send results and close channels in goroutines
	go func() {
		tcpResults <- models.Result{
			Target: models.Target{
				Host: "192.168.1.1",
				Port: 80,
				Mode: models.ModeTCP,
			},
			Available: true,
		}
		close(tcpResults)
	}()

	go func() {
		icmpResults <- models.Result{
			Target: models.Target{
				Host: "192.168.1.2",
				Mode: models.ModeICMP,
			},
			Available: true,
		}
		close(icmpResults)
	}()

	mockTCP.EXPECT().
		Scan(gomock.Any(), matchTargets(models.ModeTCP)).
		Return(tcpResults, nil)

	mockICMP.EXPECT().
		Scan(gomock.Any(), matchTargets(models.ModeICMP)).
		Return(icmpResults, nil)

	scanner := &CombinedScanner{
		tcpScanner:  mockTCP,
		icmpScanner: mockICMP,
		done:        make(chan struct{}),
	}

	results, err := scanner.Scan(ctx, targets)
	require.NoError(t, err)

	// Collect results with timeout
	var gotResults []models.Result

	resultsDone := make(chan struct{})

	go func() {
		defer close(resultsDone)

		for result := range results {
			gotResults = append(gotResults, result)
		}
	}()

	select {
	case <-resultsDone:
	case <-ctx.Done():
		t.Fatal("Test timed out waiting for results")
	}

	require.Len(t, gotResults, 2, "Expected 2 results")
}

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

func TestCombinedScanner_ScanMixed(t *testing.T) {
	ctrl, ctx := gomock.WithContext(context.Background(), t)
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

	mockTCP.EXPECT().Stop(ctx).Return(nil).AnyTimes()
	mockICMP.EXPECT().Stop(ctx).Return(nil).AnyTimes()

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

	// Collect results
	gotResults := make([]models.Result, 0, len(targets))
	for result := range results {
		gotResults = append(gotResults, result)
	}

	// Should get exactly 2 results
	require.Len(t, gotResults, 2)

	// Create maps to match results by mode since order isn't guaranteed
	expectedMap := map[models.SweepMode]models.Result{
		models.ModeTCP:  tcpResult,
		models.ModeICMP: icmpResult,
	}

	gotMap := map[models.SweepMode]models.Result{}
	for _, result := range gotResults {
		gotMap[result.Target.Mode] = result
	}

	// Compare results by mode
	for mode, expected := range expectedMap {
		got, exists := gotMap[mode]
		if assert.True(t, exists, "Missing result for mode %s", mode) {
			assert.Equal(t, expected.Target, got.Target, "Target mismatch for mode %s", mode)
			assert.Equal(t, expected.Available, got.Available, "Availability mismatch for mode %s", mode)
		}
	}
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
				mockTCP.EXPECT().Stop(gomock.Any()).Return(nil).AnyTimes()
				mockICMP.EXPECT().Stop(gomock.Any()).Return(nil).AnyTimes()
			},
			wantErr:    true,
			wantErrStr: "TCP scan error: TCP scan failed",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Create timeout context for the test
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()

			mockTCP := NewMockScanner(ctrl)
			mockICMP := NewMockScanner(ctrl)

			scanner := &CombinedScanner{
				tcpScanner:  mockTCP,
				icmpScanner: mockICMP,
				done:        make(chan struct{}),
			}

			// Setup mocks before running test
			tt.setupMocks(mockTCP, mockICMP)

			// Run scanner
			results, err := scanner.Scan(ctx, tt.targets)

			if tt.wantErr {
				require.Error(t, err)
				assert.Equal(t, tt.wantErrStr, err.Error())
				require.Nil(t, results)
			} else {
				require.NoError(t, err)
				require.NotNil(t, results)
			}

			// Clean up - give it a short timeout
			stopCtx, stopCancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer stopCancel()

			err = scanner.Stop(stopCtx)
			if err != nil {
				t.Logf("Warning: error during scanner stop: %v", err)
			}
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
