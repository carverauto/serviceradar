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

package mapper

import (
	"context"

	"time"

	"github.com/gosnmp/gosnmp"
)

// setupSNMPClient creates and configures an SNMP client without opening the socket.
func (e *DiscoveryEngine) setupSNMPClient(job *DiscoveryJob, target string) (*gosnmp.GoSNMP, error) {
	// Create SNMP client
	client, err := e.createSNMPClient(target, job.Params.Credentials)
	if err != nil {
		return nil, err
	}

	// Override timeout and retries if specified in job params
	if job.Params.Timeout > 0 {
		client.Timeout = job.Params.Timeout
	}

	if job.Params.Retries > 0 {
		client.Retries = job.Params.Retries
	}

	return client, nil
}

func (e *DiscoveryEngine) checkUniFiAPI(ctx context.Context, job *DiscoveryJob, snmpTargetIP string) {
	if len(e.config.UniFiAPIs) == 0 || (job.Params.Type != DiscoveryTypeFull && job.Params.Type != DiscoveryTypeTopology) {
		return
	}

	job.mu.Lock()
	if job.uniFiTopologyPolled {
		job.mu.Unlock()
		return
	}
	job.uniFiTopologyPolled = true
	job.mu.Unlock()

	links, err := e.queryUniFiAPI(ctx, job, snmpTargetIP)
	if err != nil {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Err(err).
			Msg("UniFi topology query returned no links or failed")
		job.mu.Lock()
		job.uniFiTopologyPolled = false
		job.mu.Unlock()
		return
	}

	if len(links) == 0 {
		// Allow subsequent attempts (other seeds/contextless) when this target produced no links.
		e.logger.Info().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Msg("UniFi topology query returned zero links")
		job.mu.Lock()
		job.uniFiTopologyPolled = false
		job.mu.Unlock()
		return
	}

	e.logger.Info().
		Str("job_id", job.ID).
		Str("target_ip", snmpTargetIP).
		Int("links", len(links)).
		Msg("UniFi topology links discovered")
	e.publishTopologyLinks(job, links, snmpTargetIP, "UniFi-API")
}

// connectSNMPClient attempts to connect to the SNMP client with a timeout
func (e *DiscoveryEngine) connectSNMPClient(
	ctx context.Context, client *gosnmp.GoSNMP, job *DiscoveryJob, snmpTargetIP string) error {
	connectCtx, connectCancel := context.WithTimeout(ctx, 10*time.Second)
	defer connectCancel()

	connectDone := make(chan error, 1)

	go func() {
		connectDone <- client.Connect()
	}()

	hostname := e.lookupKnownDeviceName(job, snmpTargetIP)
	target := describeSNMPTarget(snmpTargetIP, hostname)

	select {
	case err := <-connectDone:
		if err != nil {
			e.logger.Error().
				Str("job_id", job.ID).
				Str("target_ip", snmpTargetIP).
				Str("hostname", hostname).
				Err(err).
				Msgf("Failed to connect SNMP for %s", target)

			return err
		}
	case <-connectCtx.Done():
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Str("hostname", hostname).
			Msgf("SNMP connect timeout for %s, skipping", target)

		return ErrConnectionTimeout
	}

	return nil
}

// performDiscoveryWithTimeout is a helper function to perform discovery operations with timeout
func (e *DiscoveryEngine) performDiscoveryWithTimeout(
	ctx context.Context,
	job *DiscoveryJob,
	client *gosnmp.GoSNMP,
	snmpTargetIP string,
	discoveryTypeName string,
	requiredType DiscoveryType,
	handlerFunc func(*DiscoveryJob, *gosnmp.GoSNMP, string),
) {
	if job.Params.Type == DiscoveryTypeFull || job.Params.Type == requiredType {
		done := make(chan struct{})

		go func() {
			handlerFunc(job, client, snmpTargetIP)
			close(done)
		}()

		select {
		case <-done:
		case <-time.After(30 * time.Second):
			e.logger.Warn().Str("job_id", job.ID).Str("discovery_type", discoveryTypeName).
				Str("target_ip", snmpTargetIP).Msg("Discovery timeout")
		case <-ctx.Done():
			e.logger.Info().Str("job_id", job.ID).Str("discovery_type", discoveryTypeName).
				Str("target_ip", snmpTargetIP).Msg("Discovery canceled")
		}
	}
}

// performInterfaceDiscovery performs interface discovery with timeout
func (e *DiscoveryEngine) performInterfaceDiscovery(
	ctx context.Context, job *DiscoveryJob, client *gosnmp.GoSNMP, snmpTargetIP string) {
	e.performDiscoveryWithTimeout(
		ctx,
		job,
		client,
		snmpTargetIP,
		"Interface",
		DiscoveryTypeInterfaces,
		e.handleInterfaceDiscoverySNMP,
	)
}

// performTopologyDiscovery performs topology discovery with timeout
func (e *DiscoveryEngine) performTopologyDiscovery(
	ctx context.Context, job *DiscoveryJob, client *gosnmp.GoSNMP, snmpTargetIP string) {
	e.performDiscoveryWithTimeout(
		ctx,
		job,
		client,
		snmpTargetIP,
		"Topology",
		DiscoveryTypeTopology,
		e.handleTopologyDiscoverySNMP,
	)
}

func (e *DiscoveryEngine) scanTargetForSNMP(
	ctx context.Context, job *DiscoveryJob, snmpTargetIP string, mode snmpPollingMode,
) {
	hostname := e.lookupKnownDeviceName(job, snmpTargetIP)
	target := describeSNMPTarget(snmpTargetIP, hostname)

	e.logger.Debug().
		Str("job_id", job.ID).
		Str("target_ip", snmpTargetIP).
		Str("hostname", hostname).
		Msgf("SNMP scanning %s", target)

	// Setup SNMP client
	client, err := e.setupSNMPClient(job, snmpTargetIP)
	if err != nil {
		e.logger.Error().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Str("hostname", hostname).
			Err(err).
			Msgf("Failed to setup SNMP client for %s", target)

		return
	}

	// Connect to SNMP client
	if err = e.connectSNMPClient(ctx, client, job, snmpTargetIP); err != nil {
		return
	}

	defer func() {
		go func() {
			if cErr := client.Conn.Close(); cErr != nil {
				e.logger.Warn().Str("job_id", job.ID).Str("target_ip", snmpTargetIP).Err(cErr).
					Msg("Error closing SNMP connection")
			}
		}()
	}()

	// Query system information
	deviceSNMP, err := e.querySysInfoWithTimeout(client, job, snmpTargetIP, 15*time.Second)
	if err != nil {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("target_ip", snmpTargetIP).
			Str("hostname", hostname).
			Err(err).
			Msgf("Failed to query system info via SNMP for %s, skipping", target)

		// For topology mode, continue with LLDP/CDP/L2 polling when the target
		// is already known from other evidence (e.g., UniFi inventory).
		if mode == snmpPollingModeTopology {
			if localDeviceID := e.lookupLocalDeviceID(job, snmpTargetIP); localDeviceID != "" {
				e.logger.Info().
					Str("job_id", job.ID).
					Str("target_ip", snmpTargetIP).
					Str("local_device_id", localDeviceID).
					Msg("Continuing topology polling without sysinfo due to known device identity")
				e.performTopologyDiscovery(ctx, job, client, snmpTargetIP)
			}
		}

		return
	}

	// Lock the job while modifying results and device map
	job.mu.Lock()
	e.addOrUpdateDeviceToResults(job, deviceSNMP)
	job.mu.Unlock()

	if mode == snmpPollingModeEnrichment {
		e.performInterfaceDiscovery(ctx, job, client, snmpTargetIP)
	}

	if mode == snmpPollingModeTopology {
		e.performTopologyDiscovery(ctx, job, client, snmpTargetIP)
	}
}
