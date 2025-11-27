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

package core

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"go.uber.org/mock/gomock"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/registry"
)

var (
	errTestDB     = errors.New("db error")
	errTestDelete = errors.New("delete error")
)

func TestStaleDeviceReaper_Reap(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)
	mockRegistry := registry.NewMockManager(ctrl)
	log := logger.NewTestLogger()
	ttl := 24 * time.Hour

	reaper := NewStaleDeviceReaper(mockDB, mockRegistry, log, 1*time.Hour, ttl)

	t.Run("success_with_stale_devices", func(t *testing.T) {
		ctx := context.Background()
		staleIDs := []string{"device-1", "device-2"}

		mockDB.EXPECT().GetStaleIPOnlyDevices(ctx, ttl).Return(staleIDs, nil)
		mockDB.EXPECT().SoftDeleteDevices(ctx, staleIDs).Return(nil)
		for _, id := range staleIDs {
			mockRegistry.EXPECT().DeleteLocal(id)
		}

		err := reaper.reap(ctx)
		assert.NoError(t, err)
	})

	t.Run("success_no_stale_devices", func(t *testing.T) {
		ctx := context.Background()
		var staleIDs []string

		mockDB.EXPECT().GetStaleIPOnlyDevices(ctx, ttl).Return(staleIDs, nil)
		// SoftDeleteDevices should NOT be called

		err := reaper.reap(ctx)
		assert.NoError(t, err)
	})

	t.Run("error_getting_stale_devices", func(t *testing.T) {
		ctx := context.Background()

		mockDB.EXPECT().GetStaleIPOnlyDevices(ctx, ttl).Return(nil, errTestDB)

		err := reaper.reap(ctx)
		assert.ErrorIs(t, err, errTestDB)
	})

	t.Run("error_deleting_devices", func(t *testing.T) {
		ctx := context.Background()
		staleIDs := []string{"device-1"}

		mockDB.EXPECT().GetStaleIPOnlyDevices(ctx, ttl).Return(staleIDs, nil)
		mockDB.EXPECT().SoftDeleteDevices(ctx, staleIDs).Return(errTestDelete)

		err := reaper.reap(ctx)
		assert.ErrorIs(t, err, errTestDelete)
	})
}
