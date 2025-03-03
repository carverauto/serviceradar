/*-
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

// Package agent pkg/agent/icmp_checker.go
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/pkg/scan"
)

type ICMPChecker struct {
	Host        string
	Count       int
	scanner     scan.Scanner // cached scanner instance
	scannerOnce sync.Once    // ensures the scanner is created only once
}

type ICMPResponse struct {
	Host         string  `json:"host"`
	ResponseTime int64   `json:"response_time"` // in nanoseconds
	PacketLoss   float64 `json:"packet_loss"`
	Available    bool    `json:"available"`
}

const (
	combinedScannerTimeout = 5 * time.Second
	combinedScannerConc    = 10
	combinedScannerICMP    = 1
	combinedScannerMaxIdle = 10
	combinedScannerMaxLife = 10 * time.Minute
	combinedScannerIdle    = 5 * time.Minute
)

// initScanner ensures that the scanner is created only once.
func (p *ICMPChecker) initScanner() {
	p.scannerOnce.Do(func() {
		p.scanner = scan.NewCombinedScanner(
			combinedScannerTimeout,
			combinedScannerConc,
			combinedScannerICMP,
			combinedScannerMaxIdle,
			combinedScannerMaxLife,
			combinedScannerIdle,
		)
	})
}

func (p *ICMPChecker) Check(ctx context.Context) (available bool, response string) {
	// Initialize the scanner only once.
	p.initScanner()

	// Create a target for ICMP scanning.
	target := models.Target{
		Host: p.Host,
		Mode: models.ModeICMP,
	}

	// Use the cached scanner to scan the target.
	resultChan, err := p.scanner.Scan(ctx, []models.Target{target})
	if err != nil {
		return false, fmt.Sprintf(`{"error": "%v"}`, err)
	}

	// We only expect one result, so read the first one.
	var result models.Result
	for r := range resultChan {
		result = r

		break
	}

	// Build a response structure.
	responseStruct := struct {
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

	jsonResponse, err := json.Marshal(responseStruct)
	if err != nil {
		return false, fmt.Sprintf(`{"error": "Failed to marshal response: %v"}`, err)
	}

	return result.Available, string(jsonResponse)
}

// Close stops the cached scanner and releases its resources.
func (p *ICMPChecker) Close(ctx context.Context) error {
	if p.scanner != nil {
		return p.scanner.Stop(ctx)
	}

	return nil
}
