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

package ping

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/carverauto/serviceradar/pkg/models" // For models.Target, models.Result
	"github.com/carverauto/serviceradar/pkg/scan"   // For scan.Scanner, scan.NewICMPSweeper
)

const (
	defaultICMPTimeout   = 5 * time.Second
	defaultICMPRateLimit = 1000 // Packets per second, adjust as needed
)

// ICMPPinger implements the Pinger interface using ICMP.
type ICMPPinger struct {
	scanner scan.Scanner // Underlying ICMP scanning mechanism
	// host field is removed; it will be passed per-ping
}

// NewICMPPinger creates a new ICMPPinger.
func NewICMPPinger() (*ICMPPinger, error) {
	// Initialize the scanner. The host is not fixed at creation time.
	s, err := scan.NewICMPSweeper(defaultICMPTimeout, defaultICMPRateLimit)
	if err != nil {
		return nil, fmt.Errorf("failed to create ICMP scanner for pinger: %w", err)
	}
	return &ICMPPinger{scanner: s}, nil
}

// Ping performs a basic ICMP reachability check.
func (p *ICMPPinger) Ping(ctx context.Context, host string) (bool, error) {
	available, _, _, err := p.PingDetailed(ctx, host)
	return available, err
}

// PingDetailed performs an ICMP check and returns detailed metrics.
func (p *ICMPPinger) PingDetailed(ctx context.Context, host string) (available bool, rtt time.Duration, packetLoss float64, err error) {
	if p.scanner == nil {
		return false, 0, 0, fmt.Errorf("ICMPPinger scanner not initialized")
	}

	target := models.Target{Host: host, Mode: models.ModeICMP}
	resultChan, scanErr := p.scanner.Scan(ctx, []models.Target{target})
	if scanErr != nil {
		log.Printf("Error starting ICMP scan for host %s: %v", host, scanErr)
		return false, 0, 0, fmt.Errorf("icmp scan initiation failed for host %s: %w", host, scanErr)
	}

	var result models.Result
	select {
	case r, ok := <-resultChan:
		if !ok {
			log.Printf("ICMP result channel closed unexpectedly for host %s", host)
			return false, 0, 0, fmt.Errorf("icmp result channel closed unexpectedly for host %s", host)
		}
		result = r
	case <-ctx.Done():
		log.Printf("Context done while waiting for ICMP result for host %s: %v", host, ctx.Err())
		return false, 0, 0, fmt.Errorf("context done while waiting for ICMP result for host %s: %w", host, ctx.Err())
	}

	// result.Error might contain specific errors from the scan of that target
	return result.Available, result.RespTime, result.PacketLoss, result.Error
}

// Close releases resources used by the ICMPPinger.
func (p *ICMPPinger) Close(ctx context.Context) error {
	if p.scanner != nil {
		return p.scanner.Stop(ctx)
	}
	return nil
}
