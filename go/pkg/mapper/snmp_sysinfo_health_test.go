/*
 * Copyright 2026 Carver Automation Corporation.
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

package mapper

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// warnInfoCapture records Warn and Info lines and drops every other level.
type warnInfoCapture struct {
	logger.Logger
	mu  sync.Mutex
	buf bytes.Buffer
	out zerolog.Logger
}

func newWarnInfoCapture() *warnInfoCapture {
	c := &warnInfoCapture{Logger: logger.NewTestLogger()}
	c.out = zerolog.New(c)

	return c
}

func (c *warnInfoCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	return c.buf.Write(p)
}

func (c *warnInfoCapture) Warn() *zerolog.Event { return c.out.Warn() }
func (c *warnInfoCapture) Info() *zerolog.Event { return c.out.Info() }

func (c *warnInfoCapture) count(level, fragment string) int {
	c.mu.Lock()
	defer c.mu.Unlock()

	n := 0
	for _, line := range strings.Split(c.buf.String(), "\n") {
		if strings.Contains(line, `"level":"`+level+`"`) && strings.Contains(line, fragment) {
			n++
		}
	}

	return n
}

// A seed with no SNMP agent fails the system-info query on every pass of every
// scheduled run. It is reported once when it starts failing and again only
// after it has answered in between.
func TestUnansweredSNMPTargetWarnsOnceUntilItAnswers(t *testing.T) {
	t.Parallel()

	const (
		// Nothing listens on udp/161 on loopback, so the query is refused.
		target      = "127.0.0.1"
		failureLine = "Failed to query system info via SNMP"
	)

	capture := newWarnInfoCapture()
	engine := &DiscoveryEngine{
		config: &Config{Timeout: 200 * time.Millisecond},
		logger: capture,
	}

	// One scheduled run of a full discovery job polls each target in the
	// identity, enrichment and topology passes.
	scheduledRun := func() {
		job := testSNMPDiscoveryJob()
		job.Params.Timeout = 200 * time.Millisecond
		job.Results = &DiscoveryResults{}

		for _, mode := range []snmpPollingMode{
			snmpPollingModeIdentity, snmpPollingModeEnrichment, snmpPollingModeTopology,
		} {
			engine.scanTargetForSNMP(context.Background(), job, target, mode)
		}
	}

	scheduledRun()
	scheduledRun()
	require.Equal(t, 1, capture.count("warn", failureLine),
		"a target that never answers must be reported once, not on every pass of every run")

	// The target answers once (an SNMP agent was enabled), then stops again.
	engine.reportSysInfoAnswered(testSNMPDiscoveryJob(), target, "")
	require.Equal(t, 1, capture.count("info", "System info via SNMP answering again"))

	scheduledRun()
	require.Equal(t, 2, capture.count("warn", failureLine),
		"a target that fails again after answering must be reported again")
}
