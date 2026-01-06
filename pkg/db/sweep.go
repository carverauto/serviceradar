/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Package db pkg/db/sweep.go
package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// StoreSweepHostStates stores sweep host states in CNPG.
func (db *DB) StoreSweepHostStates(ctx context.Context, states []*models.SweepHostState) error {
	if len(states) == 0 {
		return nil
	}

	return db.cnpgInsertSweepHostStates(ctx, states)
}

// GetSweepHostStates retrieves the latest sweep host states from CNPG.
func (db *DB) GetSweepHostStates(ctx context.Context, gatewayID string, limit int) ([]*models.SweepHostState, error) {
	return db.cnpgGetSweepHostStates(ctx, gatewayID, limit)
}
