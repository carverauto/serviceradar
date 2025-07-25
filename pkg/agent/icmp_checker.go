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
	"encoding/json"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
	"github.com/carverauto/serviceradar/proto"
)

const (
	defaultICMPSweeperTimeout   = 5 * time.Second
	defaultICMPSweeperRateLimit = 1000
)

func NewICMPChecker(host string, log logger.Logger) (*ICMPChecker, error) {
	scanner, err := scan.NewICMPSweeper(defaultICMPSweeperTimeout, defaultICMPSweeperRateLimit, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	return &ICMPChecker{Host: host, scanner: scanner, logger: log}, nil
}

func NewICMPCheckerWithDeviceID(host, deviceID string, log logger.Logger) (*ICMPChecker, error) {
	scanner, err := scan.NewICMPSweeper(defaultICMPSweeperTimeout, defaultICMPSweeperRateLimit, log)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner: %w", err)
	}

	return &ICMPChecker{Host: host, DeviceID: deviceID, scanner: scanner, logger: log}, nil
}

func (p *ICMPChecker) Check(ctx context.Context, req *proto.StatusRequest) (isAccessible bool, statusMsg json.RawMessage) {
	target := models.Target{Host: p.Host, Mode: models.ModeICMP}

	resultChan, err := p.scanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return false, jsonError(fmt.Sprintf("ICMP scan failed: %v", err))
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
		AgentID:      req.AgentId,
		PollerID:     req.PollerId,
		DeviceID:     p.DeviceID,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		p.logger.Error().Err(err).Msg("failed to marshal ICMP response")
		return false, jsonError(fmt.Sprintf("Failed to marshal response: %v", err))
	}

	return result.Available, data
}

func (p *ICMPChecker) Close(ctx context.Context) error {
	return p.scanner.Stop(ctx)
}
