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
	"slices"
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

type fixedStatsScanner struct {
	statsCapabilityScanner

	stats scan.ScannerStats
}

func (s fixedStatsScanner) GetStats() scan.ScannerStats {
	return s.stats
}

func TestGetScannerStatsDropRateIsTheShareOfRepliesDropped(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		received uint64
		dropped  uint64
		want     float64
	}{
		{name: "some dropped", received: 75, dropped: 25, want: 25},
		{name: "every reply dropped", received: 0, dropped: 10, want: 100},
		{name: "nothing dropped", received: 40, dropped: 0, want: 0},
		{name: "no replies", received: 0, dropped: 0, want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			sweeper := &NetworkSweeper{
				tcpScanner: fixedStatsScanner{
					statsCapabilityScanner: statsCapabilityScanner{caps: scan.ScannerCapabilities{RawSYNIPv4: true}},
					stats:                  scan.ScannerStats{PacketsRecv: tt.received, PacketsDropped: tt.dropped},
				},
			}

			stats := sweeper.GetScannerStats()
			if stats == nil {
				t.Fatal("expected scanner stats")
				return
			}

			if stats.RxDropRatePercent != tt.want {
				t.Fatalf("rx drop rate = %v, want %v", stats.RxDropRatePercent, tt.want)
			}
		})
	}
}

func TestEffectiveSweepModesRunsIPv6SYNAsConnectWithoutRawSocket(t *testing.T) {
	s := &NetworkSweeper{}
	signed := []models.SweepMode{models.ModeICMP, models.ModeTCP}

	v6, err := s.EffectiveSweepModes("2001:db8::/126", signed)
	if err != nil {
		t.Fatal(err)
	}
	if want := []models.SweepMode{models.ModeICMP, models.ModeTCPConnect}; !slices.Equal(v6, want) {
		t.Fatalf("IPv6 modes = %v, want %v", v6, want)
	}

	v4, err := s.EffectiveSweepModes("192.0.2.0/30", signed)
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(v4, signed) {
		t.Fatalf("IPv4 modes = %v, want %v", v4, signed)
	}
}
