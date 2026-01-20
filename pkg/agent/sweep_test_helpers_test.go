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

package agent

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

// mockSweeper implements sweeper.SweepService for tests.
type mockSweeper struct {
	summary     *models.SweepSummary
	updateCount int
}

func (*mockSweeper) Start(_ context.Context) error {
	return nil
}

func (*mockSweeper) Stop() error {
	return nil
}

func (*mockSweeper) UpdateConfig(_ *models.Config) error {
	return nil
}

func (m *mockSweeper) GetStatus(_ context.Context) (*models.SweepSummary, error) {
	return m.summary, nil
}

func (*mockSweeper) GetScannerStats() *models.ScannerStats {
	return nil
}

func (m *mockSweeper) updateSummary(newSummary *models.SweepSummary) {
	if newSummary.LastSweep == m.summary.LastSweep {
		newSummary.LastSweep = time.Now().Unix()
	}

	m.summary = newSummary
	m.updateCount++
}
