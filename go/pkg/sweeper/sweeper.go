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
	"sync"
	"sync/atomic"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/go/pkg/scan"
	"github.com/carverauto/serviceradar/go/pkg/scan/banner_grab"
)

type NetworkSweeper struct {
	config            *models.Config
	icmpScanner       scan.Scanner
	tcpScanner        scan.Scanner // SYN scanner (fast but breaks conntrack)
	tcpConnectScanner scan.Scanner // TCP connect scanner (safe for conntrack)
	store             Store
	processor         ResultProcessor
	deviceRegistry    DeviceRegistryService
	logger            logger.Logger
	mu                sync.RWMutex
	runMu             sync.Mutex
	done              chan struct{}
	stopped           bool
	// manualSchedule suppresses the local interval ticker (initial sweep
	// included) while an external scheduler drives RunOnce calls, e.g. the
	// agent running core-leased sweep slots at their signed times.
	manualSchedule atomic.Bool
	lastSweep      time.Time
	// Device result aggregation for multi-IP devices
	deviceResults      map[string]*DeviceResultAggregator
	resultsMu          sync.Mutex
	tickerReset        chan struct{}
	bannerMu           sync.RWMutex
	bannerPhase        *banner_grab.Engine
	lastBannerStats    *models.BannerGrabStats
	bannerHandler      BannerObservationHandler
	sweepInProgress    bool
	lastSweepCancelled bool
	lastSummary        *models.SweepSummary
	// synScanGate is shared with the SYN scanner this sweeper builds; see
	// WithSYNScanGate.
	synScanGate *scan.SYNScanGate
	// activeRun is the in-flight run, so CancelRun can abort it. It is nil when
	// idle and once the run has published its results.
	activeRun *sweepRun
	// partialRunPending marks partial results left in the store by a cancelled
	// run. GetStatus serves lastSummary until the next sweep completes.
	partialRunPending bool
	// unavailableScannerWarned holds the modes whose "scanner is not
	// available" warning was logged, until that scanner is available again.
	unavailableScannerMu     sync.Mutex
	unavailableScannerWarned map[string]bool
}

// DeviceResultAggregator aggregates scan results for a device with multiple IPs
type DeviceResultAggregator struct {
	DeviceID    string
	Results     []*models.Result
	ExpectedIPs []string
	Metadata    map[string]interface{}
	AgentID     string
	GatewayID   string
	Partition   string
	mu          sync.Mutex
}

// Start begins periodic sweeping.
