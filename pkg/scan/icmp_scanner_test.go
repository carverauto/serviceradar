package scan

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"go.uber.org/mock/gomock"
)

func TestNewICMPSweeper(t *testing.T) {
	tests := []struct {
		name      string
		timeout   time.Duration
		rateLimit int
		wantErr   bool
	}{
		{
			name:      "default values",
			timeout:   0,
			rateLimit: 0,
			wantErr:   false,
		},
		{
			name:      "custom values",
			timeout:   2 * time.Second,
			rateLimit: 500,
			wantErr:   false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s, err := NewICMPSweeper(tt.timeout, tt.rateLimit)
			if (err != nil) != tt.wantErr {
				t.Errorf("NewICMPSweeper() error = %v, wantErr %v", err, tt.wantErr)
				return
			}

			if s == nil {
				t.Fatal("NewICMPSweeper() returned nil")
			}

			expectedTimeout := tt.timeout
			if expectedTimeout == 0 {
				expectedTimeout = defaultICMPTimeout
			}

			if s.timeout != expectedTimeout {
				t.Errorf("timeout = %v, want %v", s.timeout, expectedTimeout)
			}

			expectedRateLimit := tt.rateLimit
			if expectedRateLimit == 0 {
				expectedRateLimit = defaultICMPRateLimit
			}

			if s.rateLimit != expectedRateLimit {
				t.Errorf("rateLimit = %v, want %v", s.rateLimit, expectedRateLimit)
			}

			_ = s.Stop(context.Background())
		})
	}
}

func TestICMPSweeper_Scan(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	sweeper, err := NewICMPSweeper(1*time.Second, 100)
	if err != nil {
		t.Fatalf("Failed to create ICMPSweeper: %v", err)
	}

	defer func(sweeper *ICMPSweeper, ctx context.Context) {
		err = sweeper.Stop(ctx)
		if err != nil {
			t.Errorf("Failed to stop ICMPSweeper: %v", err)
		}
	}(sweeper, context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Use an unreachable private IP to test failure case
	targets := []models.Target{
		{Host: "192.168.255.254", Mode: models.ModeICMP}, // Typically unused
		{Host: "10.255.255.254", Mode: models.ModeICMP},  // Typically unused
	}

	resultCh, err := sweeper.Scan(ctx, targets)
	if err != nil {
		t.Fatalf("Scan() error = %v", err)
	}

	results := make([]models.Result, 0, len(targets))
	for result := range resultCh {
		results = append(results, result)
	}

	if len(results) != len(targets) {
		t.Errorf("Expected %d results, got %d", len(targets), len(results))
	}

	// In a test env without mocking, results depend on network access.
	// We expect failure for unreachable IPs, but if run with privileges, they might succeed.
	for _, r := range results {
		if r.Available {
			t.Logf("Note: %s was reachable; test assumes unreachable targets", r.Target.Host)
		} else if r.PacketLoss != 100 {
			t.Errorf("Expected 100%% packet loss for %s, got %f", r.Target.Host, r.PacketLoss)
		}
	}
}

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

func TestICMPSweeper_Stop(t *testing.T) {
	sweeper, err := NewICMPSweeper(1*time.Second, 100)
	if err != nil {
		t.Fatalf("Failed to create ICMPSweeper: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	sweeper.cancel = cancel

	err = sweeper.Stop(context.Background())
	if err != nil {
		t.Errorf("Stop() error = %v", err)
	}

	// Check that rawSocketFD is closed
	if sweeper.rawSocketFD != 0 {
		t.Errorf("rawSocketFD not reset after Stop()")
	}

	// Check that context was canceled
	select {
	case <-ctx.Done():
		// Expected
	default:
		t.Errorf("Context not canceled after Stop()")
	}
}
