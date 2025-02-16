package snmp

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"
)

func TestCollector_WithMocks(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	tests := []struct {
		name      string
		setupMock func(*MockCollector) error
		wantErr   bool
	}{
		{
			name: "successful collection",
			setupMock: func(mc *MockCollector) error {
				// Set up expectations before calling Start
				dataChan := make(chan DataPoint, 1)
				mc.EXPECT().GetResults().Return((<-chan DataPoint)(dataChan))
				mc.EXPECT().Stop().Return(nil)
				mc.EXPECT().Start(gomock.Any()).Return(nil)

				return nil
			},
			wantErr: false,
		},
		{
			name: "start failure",
			setupMock: func(mc *MockCollector) error {
				mc.EXPECT().Start(gomock.Any()).Return(assert.AnError)
				return assert.AnError
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockCollector := NewMockCollector(ctrl)
			err := tt.setupMock(mockCollector)

			ctx := context.Background()
			actualErr := mockCollector.Start(ctx)

			if tt.wantErr {
				assert.Error(t, actualErr)
				assert.Equal(t, err, actualErr)
			} else {
				assert.NoError(t, actualErr)

				// Call Stop for successful tests to satisfy mock expectations
				err = mockCollector.Stop()
				assert.NoError(t, err)
			}
		})
	}
}
