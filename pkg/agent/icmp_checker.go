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

	// Take first result as we only sent one target
	var result models.Result
	for r := range resultChan {
		result = r
		break
	}

	// Format response
	response := struct {
		Host         string  `json:"host"`
		ResponseTime int64   `json:"response_time"` // in nanoseconds
		PacketLoss   float64 `json:"packet_loss"`
		Available    bool    `json:"available"`
	}{
		Host:         p.Host,
		ResponseTime: result.RespTime.Nanoseconds(),
		PacketLoss:   result.PacketLoss,
		Available:    result.Available,
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to marshal response: %v"}`, err)
	}

	return result.Available, string(jsonResponse)
}
