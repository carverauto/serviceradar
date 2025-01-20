package scan

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/mock/gomock"
)

func TestCombinedScanner_Scan(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name        string
		targets     []models.Target
		setupMocks  func(mockTCP, mockICMP *MockScanner)
		wantErr     bool
		wantErrStr  string
		wantResults []models.Result
	}{
		{
			name: "successful mixed scan",
			targets: []models.Target{
				{Host: "192.168.1.1", Port: 80, Mode: models.ModeTCP},
				{Host: "192.168.1.2", Mode: models.ModeICMP},
			},
			setupMocks: func(mockTCP, mockICMP *MockScanner) {
				tcpResults := make(chan models.Result, 1)
				icmpResults := make(chan models.Result, 1)

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
			},
			wantResults: []models.Result{
				{
					Target: models.Target{
						Host: "192.168.1.1",
						Port: 80,
						Mode: models.ModeTCP,
					},
					Available: true,
				},
				{
					Target: models.Target{
						Host: "192.168.1.2",
						Mode: models.ModeICMP,
					},
					Available: true,
				},
			},
		},
		{
			name: "TCP scanner error",
			targets: []models.Target{
				{Host: "192.168.1.1", Port: 80, Mode: models.ModeTCP},
			},
			setupMocks: func(mockTCP, mockICMP *MockScanner) {
				mockTCP.EXPECT().
					Scan(gomock.Any(), gomock.Any()).
					Return(nil, errors.New("TCP scan failed"))
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
					Return(nil, errors.New("ICMP scan failed"))
				mockTCP.EXPECT().Stop().Return(nil).AnyTimes()
				mockICMP.EXPECT().Stop().Return(nil).AnyTimes()
			},
			wantErr:    true,
			wantErrStr: "ICMP scan error: ICMP scan failed",
		},
		{
			name:    "empty targets",
			targets: []models.Target{},
			setupMocks: func(mockTCP, mockICMP *MockScanner) {
				mockTCP.EXPECT().Stop().Return(nil).AnyTimes()
				mockICMP.EXPECT().Stop().Return(nil).AnyTimes()
			},
			wantResults: []models.Result{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockTCP := NewMockScanner(ctrl)
			mockICMP := NewMockScanner(ctrl)

			if tt.setupMocks != nil {
				tt.setupMocks(mockTCP, mockICMP)
			}

			scanner := &CombinedScanner{
				tcpScanner:  mockTCP,
				icmpScanner: mockICMP,
				done:        make(chan struct{}),
			}

			ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
			defer cancel()

			results, err := scanner.Scan(ctx, tt.targets)

			if tt.wantErr {
				require.Error(t, err)
				assert.Equal(t, tt.wantErrStr, err.Error())
				return
			}

			require.NoError(t, err)
			require.NotNil(t, results)

			var gotResults []models.Result
			for result := range results {
				gotResults = append(gotResults, result)
			}

			if len(tt.wantResults) == 0 {
				assert.Empty(t, gotResults)
			} else {
				assert.Equal(t, len(tt.wantResults), len(gotResults))
				for i := range tt.wantResults {
					assert.Equal(t, tt.wantResults[i].Target, gotResults[i].Target)
					assert.Equal(t, tt.wantResults[i].Available, gotResults[i].Available)
				}
			}
		})
	}
}

// Helper matcher for testing target modes
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
