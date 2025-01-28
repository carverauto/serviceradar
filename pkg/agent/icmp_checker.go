// Package agent pkg/agent/icmp_checker.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/mfreeman451/serviceradar/pkg/models"
	"github.com/mfreeman451/serviceradar/pkg/scan"
)

type ICMPChecker struct {
	Host  string
	Count int
}

type ICMPResponse struct {
	Host         string  `json:"host"`
	ResponseTime int64   `json:"response_time"` // in nanoseconds
	PacketLoss   float64 `json:"packet_loss"`
	Available    bool    `json:"available"`
}

func (p *ICMPChecker) Check(ctx context.Context) (bool, string) {
	scanner := scan.NewCombinedScanner(time.Duration(p.Count)*time.Second, 1, p.Count)

	target := models.Target{
		Host: p.Host,
		Mode: models.ModeICMP,
	}

	resultChan, err := scanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return false, fmt.Sprintf(`{"error": "%v"}`, err)
	}

	var totalResponseTime time.Duration
	var successfulPings int
	var packetLoss float64

	for result := range resultChan {
		if result.Error != nil {
			return false, fmt.Sprintf(`{"error": "%v"}`, result.Error)
		}

		if result.Available {
			totalResponseTime += result.RespTime
			successfulPings++
		}
	}

	if p.Count > 0 {
		packetLoss = float64(p.Count-successfulPings) / float64(p.Count) * 100
	}

	available := successfulPings > 0
	avgResponseTime := int64(0)
	if successfulPings > 0 {
		avgResponseTime = totalResponseTime.Nanoseconds() / int64(successfulPings)
	}

	response := ICMPResponse{
		Host:         p.Host,
		ResponseTime: avgResponseTime,
		PacketLoss:   packetLoss,
		Available:    available,
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to marshal response: %v"}`, err)
	}

	return available, string(jsonResponse)
}
