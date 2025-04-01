//go:build !ci
// +build !ci

package scan

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"go.uber.org/mock/gomock"
)

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
