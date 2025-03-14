package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

func NewICMPChecker(host string) (*ICMPChecker, error) {
	scanner, err := scan.NewICMPSweeper(5*time.Second, 1000)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}
	return &ICMPChecker{Host: host, scanner: scanner}, nil
}

func (p *ICMPChecker) Check(ctx context.Context) (bool, string) {
	target := models.Target{Host: p.Host, Mode: models.ModeICMP}
	resultChan, err := p.scanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return false, fmt.Sprintf(`{"error": "%v"}`, err)
	}

	var result models.Result
	for r := range resultChan {
		result = r
		break
	}

	resp := ICMPResponse{
		Host:         p.Host,
		ResponseTime: result.RespTime.Nanoseconds(),
		PacketLoss:   result.PacketLoss,
		Available:    result.Available,
	}
	jsonResp, _ := json.Marshal(resp)
	return result.Available, string(jsonResp)
}

func (p *ICMPChecker) Close(ctx context.Context) error {
	return p.scanner.Stop(ctx)
}
