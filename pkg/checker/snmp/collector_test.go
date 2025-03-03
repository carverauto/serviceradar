/*-
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

// Package snmp pkg/checker/snmp/service_test.go
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
		setupMock func(*MockCollector)
		runTest   func(*MockCollector) error
		wantErr   bool
	}{
		{
			name: "successful collection",
			setupMock: func(mc *MockCollector) {
				dataChan := make(chan DataPoint, 1)
				mc.EXPECT().Start(gomock.Any()).Return(nil)
				mc.EXPECT().GetResults().Return(dataChan).AnyTimes()
				mc.EXPECT().Stop().Return(nil)
			},
			runTest: func(mc *MockCollector) error {
				ctx := context.Background()
				if err := mc.Start(ctx); err != nil {
					return err
				}
				_ = mc.GetResults() // Ensure GetResults is called
				return mc.Stop()
			},
			wantErr: false,
		},
		{
			name: "start failure",
			setupMock: func(mc *MockCollector) {
				mc.EXPECT().Start(gomock.Any()).Return(assert.AnError)
				mc.EXPECT().GetResults().Return(make(<-chan DataPoint)).AnyTimes()
			},
			runTest: func(mc *MockCollector) error {
				ctx := context.Background()
				if err := mc.Start(ctx); err != nil {
					_ = mc.GetResults() // Ensure GetResults is called even in error case
					return err
				}
				return nil
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			mockCollector := NewMockCollector(ctrl)
			tt.setupMock(mockCollector)

			err := tt.runTest(mockCollector)

			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}
