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

package sweeper

import (
	"context"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
)

type statsCapabilityScanner struct {
	caps scan.ScannerCapabilities
}

func (s statsCapabilityScanner) Scan(context.Context, []models.Target) (<-chan models.Result, error) {
	results := make(chan models.Result)
	close(results)

	return results, nil
}

func (s statsCapabilityScanner) Stop() error {
	return nil
}

func (s statsCapabilityScanner) GetStats() scan.ScannerStats {
	return scan.ScannerStats{PacketsSent: 5}
}

func (s statsCapabilityScanner) Capabilities() scan.ScannerCapabilities {
	return s.caps
}

func TestGetScannerStatsLabelsRawSYNIPv4(t *testing.T) {
	t.Parallel()

	sweeper := &NetworkSweeper{
		tcpScanner: statsCapabilityScanner{
			caps: scan.ScannerCapabilities{RawSYNIPv4: true},
		},
	}

	stats := sweeper.GetScannerStats()
	if stats == nil {
		t.Fatal("expected scanner stats")
	}
	if stats.Protocol != "tcp" {
		t.Fatalf("protocol = %q, want tcp", stats.Protocol)
	}
	if stats.AddressFamily != "ipv4" {
		t.Fatalf("address family = %q, want ipv4", stats.AddressFamily)
	}
	if stats.ScannerPath != "raw_syn" {
		t.Fatalf("scanner path = %q, want raw_syn", stats.ScannerPath)
	}
	if stats.PacketsSent != 5 {
		t.Fatalf("packets sent = %d, want 5", stats.PacketsSent)
	}
}

func TestScannerStatsLabelsRawSYNDualStack(t *testing.T) {
	t.Parallel()

	_, addressFamily, scannerPath := scannerStatsLabels(statsCapabilityScanner{
		caps: scan.ScannerCapabilities{RawSYNIPv4: true, RawSYNIPv6: true},
	})

	if addressFamily != "dual_stack" {
		t.Fatalf("address family = %q, want dual_stack", addressFamily)
	}
	if scannerPath != "raw_syn" {
		t.Fatalf("scanner path = %q, want raw_syn", scannerPath)
	}
}
