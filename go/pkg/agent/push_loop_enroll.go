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
	"errors"
	"os"
	"runtime"
	"strings"
	"time"

	agentgateway "github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// attemptConnectionAndEnrollment tries to establish gateway connection and enroll.
// Called periodically when the agent is not yet enrolled.
func (p *PushLoop) attemptConnectionAndEnrollment(ctx context.Context) {
	if p.gateway.IsConnected() {
		// Already connected, just try to enroll
		p.enroll(ctx)
		return
	}

	// Not connected, attempt reconnection with backoff
	p.logger.Debug().Msg("Attempting gateway connection")
	if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
		p.logger.Warn().Err(err).Msg("Gateway connection attempt failed")
		return
	}

	// Connected, now try to enroll
	p.logger.Info().Msg("Gateway connection established, attempting enrollment")
	p.enroll(ctx)
}

// enroll starts the enrollment loop (single in-flight attempt with retries).
func (p *PushLoop) enroll(ctx context.Context) {
	p.enrollMu.Lock()
	if p.enrollInFlight {
		p.enrollMu.Unlock()
		return
	}
	p.enrollInFlight = true
	p.enrollMu.Unlock()

	go p.enrollLoop(ctx)
}

func (p *PushLoop) enrollLoop(ctx context.Context) {
	defer func() {
		p.enrollMu.Lock()
		p.enrollInFlight = false
		p.enrollMu.Unlock()
	}()

	p.logger.Info().Msg("Enrolling with gateway...")

	delay := defaultEnrollRetryDelay
	for {
		if ctx.Err() != nil {
			return
		}

		if err := p.enrollOnce(ctx); err == nil {
			return
		} else if isRetryableEnrollError(err) {
			p.logger.Warn().
				Err(err).
				Dur("retry_in", delay).
				Msg("Enrollment failed, retrying")
		} else {
			p.logger.Error().Err(err).Msg("Failed to enroll with gateway")
			return
		}

		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-p.stopCh:
			timer.Stop()
			return
		case <-timer.C:
		}

		delay *= 2
		if delay > maxEnrollRetryDelay {
			delay = maxEnrollRetryDelay
		}
	}
}

// enrollOnce sends Hello to the gateway and fetches initial config.
func (p *PushLoop) enrollOnce(ctx context.Context) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}

	if !p.gateway.IsConnected() {
		if err := p.gateway.ReconnectWithBackoff(ctx); err != nil {
			return err
		}
	}

	// Build Hello request
	p.server.mu.RLock()
	var cfg ServerConfig
	if p.server.config != nil {
		cfg = *p.server.config
	}
	agentID := cfg.AgentID
	p.server.mu.RUnlock()
	hostname, err := os.Hostname()
	if err != nil {
		hostname = ""
	}
	helloReq := &proto.AgentHelloRequest{
		AgentId:       agentID,
		Version:       Version, // Agent version from version.go
		Capabilities:  p.getAgentCapabilities(&cfg),
		Hostname:      hostname,
		Os:            runtime.GOOS,
		Arch:          runtime.GOARCH,
		ConfigVersion: p.getConfigVersion(),
		Labels:        deploymentHelloLabels(),
		// Report the agent's own host IP so the gateway links it to the
		// correct device even when the TCP peer IP is NAT'd (external agents).
		// Mirrors getSourceIP() used for PushStatus so the two agree.
		HostIp: p.getSourceIP(),
	}

	// Send Hello
	helloResp, err := p.gateway.Hello(ctx, helloReq)
	if err != nil {
		return err
	}

	// Update push interval if specified by gateway
	if helloResp.HeartbeatIntervalSec > 0 {
		newInterval := time.Duration(helloResp.HeartbeatIntervalSec) * time.Second
		if newInterval < time.Second {
			newInterval = time.Second
		}
		if newInterval > time.Hour {
			newInterval = time.Hour
		}
		if newInterval != p.getInterval() {
			p.setInterval(newInterval)
			p.logger.Info().Dur("interval", newInterval).Msg("Updated push interval from gateway")
			if !p.isStatusDebounceConfigured() {
				p.setStatusDebounceInterval(newInterval)
			}
		}
		if !p.isStatusHeartbeatConfigured() {
			p.setStatusHeartbeatInterval(newInterval)
		}
	}

	p.setEnrolled(true)
	p.logger.Info().
		Str("agent_id", helloResp.AgentId).
		Str("gateway_id", helloResp.GatewayId).
		Msg("Successfully enrolled with gateway")

	// Fetch initial config if outdated or not yet fetched
	if helloResp.ConfigOutdated || p.getConfigVersion() == "" {
		p.fetchAndApplyConfig(ctx)
	}

	return nil
}

func isRetryableEnrollError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.Canceled) {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return true
	}
	if errors.Is(err, agentgateway.ErrGatewayNotConnected) {
		return true
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded:
		return true
	case codes.OK,
		codes.Canceled,
		codes.Unknown,
		codes.InvalidArgument,
		codes.NotFound,
		codes.AlreadyExists,
		codes.PermissionDenied,
		codes.ResourceExhausted,
		codes.FailedPrecondition,
		codes.Aborted,
		codes.OutOfRange,
		codes.Unimplemented,
		codes.Internal,
		codes.DataLoss,
		codes.Unauthenticated:
		return false
	}
	return false
}

func (p *PushLoop) monitorReleaseActivation(ctx context.Context) {
	state, err := LoadReleaseActivationState("")
	if err != nil {
		p.logger.Warn().Err(err).Msg("Failed to load release activation state")
		return
	}
	if state == nil || strings.TrimSpace(state.TargetVersion) != strings.TrimSpace(Version) {
		return
	}

	deadline := time.Unix(state.RollbackAtUnix, 0)
	if deadline.IsZero() {
		deadline = time.Now().Add(3 * time.Minute)
	}

	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for {
		if p.isEnrolled() {
			completed, err := CompleteReleaseActivation("", Version)
			if err != nil {
				p.logger.Warn().Err(err).Msg("Failed to finalize release activation")
			} else if completed {
				p.logger.Info().
					Str("version", Version).
					Msg("Release activation marked healthy after gateway enrollment")
			}
			return
		}

		if time.Now().After(deadline) {
			rolledBack, err := RollbackReleaseActivation("", "agent failed to become healthy before deadline")
			if err != nil {
				p.logger.Error().Err(err).Msg("Failed to roll back release activation")
				return
			}
			if rolledBack {
				p.logger.Warn().
					Str("version", Version).
					Msg("Rolled back release activation after reconnect deadline")
				requestSelfTermination()
			}
			return
		}

		select {
		case <-ctx.Done():
			return
		case <-p.stopCh:
			return
		case <-ticker.C:
		}
	}
}
