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

package metrics

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"go.uber.org/mock/gomock"
)

func TestManager(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	// Create a mock db.Service (no expectations needed for ICMP tests)
	mockDB := db.NewMockService(ctrl)

	cfg := models.MetricsConfig{
		Enabled:   true,
		Retention: 100,
	}

	t.Run("adds metrics and tracks active nodes", func(t *testing.T) {
		manager := NewManager(cfg, mockDB)
		now := time.Now()

		// Add metrics for two nodes
		err := manager.AddMetric("node1", now, 100, "service1")
		if err != nil {
			t.Fatalf("AddMetric failed: %v", err)
		}

		err = manager.AddMetric("node2", now, 200, "service2")
		if err != nil {
			t.Fatalf("AddMetric failed: %v", err)
		}

		// Verify active nodes count
		if count := manager.GetActiveNodes(); count != 2 {
			t.Errorf("expected 2 active nodes, got %d", count)
		}

		// Verify metrics retrieval
		metrics := manager.GetMetrics("node1")
		if len(metrics) != cfg.Retention {
			t.Errorf("expected %d metrics, got %d", cfg.Retention, len(metrics))
		}
	})

	t.Run("disabled metrics", func(t *testing.T) {
		disabledCfg := models.MetricsConfig{Enabled: false}
		manager := NewManager(disabledCfg, mockDB)

		err := manager.AddMetric("node1", time.Now(), 100, "service")
		if err != nil {
			t.Errorf("expected nil error for disabled metrics, got %v", err)
		}

		metrics := manager.GetMetrics("node1")
		if metrics != nil {
			t.Error("expected nil metrics when disabled")
		}
	})

	t.Run("concurrent access", func(_ *testing.T) {
		manager := NewManager(cfg, mockDB)
		done := make(chan bool)

		const goroutines = 10

		const iterations = 100

		for i := 0; i < goroutines; i++ {
			go func(id int) {
				for j := 0; j < iterations; j++ {
					_ = manager.AddMetric("node1", time.Now(), int64(id*1000+j), "test")
				}
				done <- true
			}(i)
		}

		for i := 0; i < goroutines; i++ {
			<-done
		}
	})
}
