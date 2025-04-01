package scan

import (
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
)

func TestCalculatePacketsPerInterval(t *testing.T) {
	sweeper := &ICMPSweeper{rateLimit: 1000}
	packets := sweeper.calculatePacketsPerInterval()

	expected := 10 // 1000 / (1000 / 10ms) = 10 packets
	if packets != expected {
		t.Errorf("calculatePacketsPerInterval() = %d, want %d", packets, expected)
	}

	sweeper.rateLimit = 50

	packets = sweeper.calculatePacketsPerInterval()
	if packets != 1 { // Minimum is 1
		t.Errorf("calculatePacketsPerInterval() = %d, want 1 for low rate", packets)
	}
}

func TestProcessResults(t *testing.T) {
	sweeper := &ICMPSweeper{
		results: make(map[string]models.Result),
		mu:      sync.Mutex{},
	}

	targets := []models.Target{
		{Host: "8.8.8.8", Mode: models.ModeICMP},
		{Host: "1.1.1.1", Mode: models.ModeICMP},
	}

	now := time.Now()
	sweeper.results["8.8.8.8"] = models.Result{
		Target:     targets[0],
		Available:  true,
		RespTime:   10 * time.Millisecond,
		PacketLoss: 0,
		FirstSeen:  now,
		LastSeen:   now,
	}

	resultCh := make(chan models.Result, len(targets))
	sweeper.processResults(targets, resultCh)
	close(resultCh)

	results := make([]models.Result, 0, len(targets))
	for r := range resultCh {
		results = append(results, r)
	}

	if len(results) != len(targets) {
		t.Errorf("processResults() sent %d results, want %d", len(results), len(targets))
	}

	for _, r := range results {
		if r.Target.Host == "8.8.8.8" && !r.Available {
			t.Errorf("Expected 8.8.8.8 to be available")
		}

		if r.Target.Host == "1.1.1.1" && r.Available {
			t.Errorf("Expected 1.1.1.1 to be unavailable")
		}
	}
}
