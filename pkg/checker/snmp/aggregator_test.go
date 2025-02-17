package snmp

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
)

func TestAggregator_WithMocks(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockAggregator := NewMockAggregator(ctrl)

	// Test data
	testPoint := DataPoint{
		OIDName:   "test.oid",
		Value:     float64(123),
		Timestamp: time.Now(),
	}

	// Test different aggregation scenarios
	tests := []struct {
		name          string
		setupMock     func()
		testFunction  func() error
		expectedError bool
	}{
		{
			name: "successful aggregation",
			setupMock: func() {
				mockAggregator.EXPECT().
					AddPoint(gomock.Any()).
					Do(func(point DataPoint) {
						assert.Equal(t, testPoint.OIDName, point.OIDName)
						assert.Equal(t, testPoint.Value, point.Value)
					})

				mockAggregator.EXPECT().
					GetAggregatedData(testPoint.OIDName, Minute).
					Return(&testPoint, nil)
			},
			testFunction: func() error {
				mockAggregator.AddPoint(&testPoint)
				_, err := mockAggregator.GetAggregatedData(testPoint.OIDName, Minute)
				return err
			},
			expectedError: false,
		},
		{
			name: "aggregation error",
			setupMock: func() {
				mockAggregator.EXPECT().
					GetAggregatedData(testPoint.OIDName, Minute).
					Return(nil, assert.AnError)
			},
			testFunction: func() error {
				_, err := mockAggregator.GetAggregatedData(testPoint.OIDName, Minute)
				return err
			},
			expectedError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tt.setupMock()
			err := tt.testFunction()

			if tt.expectedError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}
