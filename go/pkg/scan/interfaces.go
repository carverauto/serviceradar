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

package scan

import (
	"context"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

//go:generate mockgen -destination=mock_scanner.go -package=scan github.com/carverauto/serviceradar/go/pkg/scan Scanner,ResultProcessor

// Scanner defines how to perform network sweeps.
type Scanner interface {
	// Scan performs the sweep and returns results through the channel
	Scan(context.Context, []models.Target) (<-chan models.Result, error)
	// Stop gracefully stops any ongoing scans
	Stop() error
}

// StreamOptions tunes bounded scanner-owned batching for streamed target input.
type StreamOptions struct {
	TargetEstimate int
	BatchSize      int
}

// StreamingScanner is an optional Scanner extension for callers that can produce
// targets incrementally without materializing the full target list.
type StreamingScanner interface {
	ScanStream(context.Context, <-chan models.Target, StreamOptions) (<-chan models.Result, <-chan error, error)
}

// StatsProvider is an optional interface for scanners that can provide statistics.
type StatsProvider interface {
	// GetStats returns a snapshot of scanner performance statistics
	GetStats() ScannerStats
}

// ScannerCapabilities describes protocol and address-family support that is
// available at runtime for a scanner instance.
type ScannerCapabilities struct {
	ICMPv4         bool
	ICMPv6         bool
	TCPConnectIPv4 bool
	TCPConnectIPv6 bool
	RawSYNIPv4     bool
	RawSYNIPv6     bool
	Diagnostics    map[string]string
}

// CapabilityProvider is an optional interface for scanners that can report
// runtime protocol/address-family support.
type CapabilityProvider interface {
	Capabilities() ScannerCapabilities
}

// ResultProcessor defines how to process and aggregate sweep results.
type ResultProcessor interface {
	// Process takes a Result and updates internal state
	Process(result *models.Result) error
	// GetSummary returns the current summary of all processed results
	GetSummary() (*models.SweepSummary, error)
	// Reset clears the processor's state
	Reset()
}
