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
	return scan.ScannerStats{PacketsSent: 5, RetriesDropped: 3, DialsStarted: 7}
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
		return
	}
	if stats.Protocol != scannerProtocolTCP {
		t.Fatalf("protocol = %q, want %s", stats.Protocol, scannerProtocolTCP)
	}
	if stats.AddressFamily != addressFamilyIPv4 {
		t.Fatalf("address family = %q, want %s", stats.AddressFamily, addressFamilyIPv4)
	}
	if stats.ScannerPath != scannerPathRawSYN {
		t.Fatalf("scanner path = %q, want %s", stats.ScannerPath, scannerPathRawSYN)
	}
	if stats.PacketsSent != 5 {
		t.Fatalf("packets sent = %d, want 5", stats.PacketsSent)
	}
	if stats.RetriesDropped != 3 {
		t.Fatalf("retries dropped = %d, want 3", stats.RetriesDropped)
	}
}

func TestGetScannerStatsLabelsTCPConnect(t *testing.T) {
	t.Parallel()

	sweeper := &NetworkSweeper{
		tcpScanner: statsCapabilityScanner{
			caps: scan.ScannerCapabilities{TCPConnectIPv4: true, TCPConnectIPv6: true},
		},
	}

	stats := sweeper.GetScannerStats()
	if stats == nil {
		t.Fatal("expected scanner stats")
		return
	}
	if stats.AddressFamily != addressFamilyDualStack {
		t.Fatalf("address family = %q, want %s", stats.AddressFamily, addressFamilyDualStack)
	}
	if stats.ScannerPath != scannerPathTCPConnect {
		t.Fatalf("scanner path = %q, want %s", stats.ScannerPath, scannerPathTCPConnect)
	}
	if stats.DialsStarted != 7 {
		t.Fatalf("dials started = %d, want 7", stats.DialsStarted)
	}
}

func TestScannerStatsLabelsRawSYNDualStack(t *testing.T) {
	t.Parallel()

	addressFamily := scannerStatsAddressFamily(statsCapabilityScanner{
		caps: scan.ScannerCapabilities{RawSYNIPv4: true, RawSYNIPv6: true},
	})

	if addressFamily != addressFamilyDualStack {
		t.Fatalf("address family = %q, want %s", addressFamily, addressFamilyDualStack)
	}
}
