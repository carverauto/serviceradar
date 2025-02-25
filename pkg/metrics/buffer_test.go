package metrics

import (
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"go.uber.org/mock/gomock"
)

func TestManager(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	cfg := models.MetricsConfig{
		Enabled:   true,
		Retention: 100,
	}

	t.Run("adds metrics and tracks active nodes", func(t *testing.T) {
		manager := NewManager(cfg)
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
		if count := manager.(*Manager).GetActiveNodes(); count != 2 {
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
		manager := NewManager(disabledCfg)

		err := manager.AddMetric("node1", time.Now(), 100, "service")
		if err != nil {
			t.Errorf("expected nil error for disabled metrics, got %v", err)
		}

		metrics := manager.GetMetrics("node1")
		if metrics != nil {
			t.Error("expected nil metrics when disabled")
		}
	})

	t.Run("concurrent access", func(*testing.T) {
		manager := NewManager(cfg)
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
