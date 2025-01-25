// Package agent pkg/agent/icmp_checker.go
package agent

import (
	"context"
	"fmt"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
)

type ICMPChecker struct {
	Host  string
	Count int
}

func (p *ICMPChecker) Check(ctx context.Context) (bool, string) {
	scanner := scan.NewCombinedScanner(2*time.Second, 1, p.Count)

	target := models.Target{
		Host: p.Host,
		Mode: models.ModeICMP,
	}

	resultChan, err := scanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return false, fmt.Sprintf("ICMP check failed: %v", err)
	}

	var totalResponseTime time.Duration

	var successfulPings int

	for result := range resultChan {
		if result.Error != nil {
			return false, result.Error.Error()
		}

		if result.Available {
			totalResponseTime += result.RespTime
			successfulPings++
		}
	}

	if successfulPings == 0 {
		return false, "No successful ICMP replies"
	}

	avgResponseTime := totalResponseTime / time.Duration(successfulPings)
	return true, fmt.Sprintf("%d", avgResponseTime.Nanoseconds()) // Return raw nanoseconds
}
