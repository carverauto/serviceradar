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

package poller

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func newAgentPoller(
	name string,
	config *AgentConfig,
	client proto.AgentServiceClient,
	poller *Poller) *AgentPoller {
	// Create filtered config that excludes checks with results_interval
	filteredConfig := &AgentConfig{
		Address:  config.Address,
		Security: config.Security,
		Checks:   make([]Check, 0, len(config.Checks)),
	}

	ap := &AgentPoller{
		name:       name,
		config:     filteredConfig,
		client:     client,
		timeout:    defaultTimeout,
		poller:     poller,
		deviceIP:   "",
		deviceHost: "",
	}

	deviceIP, deviceHost := resolveAgentHostMetadata(name, config, poller.resolvedSourceIP, poller.logger)
	ap.deviceIP = deviceIP
	ap.deviceHost = deviceHost

	for _, check := range config.Checks {
		if check.ResultsInterval != nil {
			// Checks with results_interval go to results pollers
			resultsPoller := &ResultsPoller{
				client:     client,
				check:      check,
				pollerID:   poller.config.PollerID,
				agentName:  name,
				interval:   time.Duration(*check.ResultsInterval),
				poller:     poller,
				logger:     poller.logger,
				deviceIP:   deviceIP,
				deviceHost: deviceHost,
				kvStoreId: func() string {
					if poller.config.KVDomain != "" {
						return poller.config.KVDomain
					}
					return poller.config.KVAddress
				}(),
			}
			ap.resultsPollers = append(ap.resultsPollers, resultsPoller)
		} else {
			// Regular checks stay in the agent poller
			filteredConfig.Checks = append(filteredConfig.Checks, check)
		}
	}

	poller.logger.Debug().
		Str("agent", name).
		Int("total_checks", len(config.Checks)).
		Int("regular_checks", len(filteredConfig.Checks)).
		Int("results_pollers", len(ap.resultsPollers)).
		Msg("Agent poller created with filtered checks")

	return ap
}

func resolveAgentHostMetadata(agentName string, config *AgentConfig, fallbackIP string, log logger.Logger) (ip string, host string) {
	candidates := make([]string, 0, 4)

	// Environment override takes precedence (allowing explicit configuration per agent)
	envKey := fmt.Sprintf("SERVICERADAR_AGENT_%s_IP", strings.ToUpper(strings.ReplaceAll(agentName, "-", "_")))
	if envIP := os.Getenv(envKey); envIP != "" {
		candidates = append(candidates, envIP)
	}

	if config.Address != "" {
		hostCandidate := config.Address
		if hostPart, _, err := net.SplitHostPort(config.Address); err == nil && hostPart != "" {
			hostCandidate = hostPart
		}
		candidates = append(candidates, hostCandidate)
	}

	// Agent name may be resolvable in some environments (e.g., bare-metal DNS)
	candidates = append(candidates, agentName)

	// Finally fall back to the poller's resolved source IP if we need to co-locate
	if fallbackIP != "" {
		candidates = append(candidates, fallbackIP)
	}

	for _, candidate := range candidates {
		cleaned := sanitizeTelemetryString(candidate)
		if cleaned == "" {
			continue
		}

		if host == "" && !strings.HasPrefix(cleaned, ":") {
			host = cleaned
		}

		if ip != "" {
			continue
		}

		if parsed := net.ParseIP(cleaned); parsed != nil {
			if v4 := parsed.To4(); v4 != nil {
				ip = v4.String()
				break
			}
			ip = parsed.String()
			break
		}

		addrs, err := lookupHostIPs(cleaned)
		if err != nil {
			log.Debug().
				Str("agent", agentName).
				Str("candidate", cleaned).
				Err(err).
				Msg("Failed to resolve agent host candidate")
			continue
		}

		for _, addr := range addrs {
			if v4 := addr.To4(); v4 != nil {
				ip = v4.String()
				break
			}
		}

		if ip == "" && len(addrs) > 0 {
			ip = addrs[0].String()
		}

		if ip != "" {
			break
		}
	}

	if ip == "" && fallbackIP != "" {
		ip = fallbackIP
		log.Debug().
			Str("agent", agentName).
			Str("fallback_ip", fallbackIP).
			Msg("Using poller source IP as fallback agent address")
	}

	if host == "" {
		host = agentName
	}

	return ip, host
}

// ExecuteChecks runs all configured service checks for the agent.
func (ap *AgentPoller) ExecuteChecks(ctx context.Context) []*proto.ServiceStatus {
	checkCtx, cancel := context.WithTimeout(ctx, ap.timeout)
	defer cancel()

	results := make(chan *proto.ServiceStatus, len(ap.config.Checks))
	statuses := make([]*proto.ServiceStatus, 0, len(ap.config.Checks))

	var wg sync.WaitGroup

	for _, check := range ap.config.Checks {
		wg.Add(1)

		go func(check Check) {
			defer wg.Done()

			kvID := ap.poller.config.KVDomain
			if kvID == "" {
				kvID = ap.poller.config.KVAddress
			}
			svcCheck := newServiceCheck(ap.client, check, ap.poller.config.PollerID, ap.name, kvID, ap.deviceIP, ap.deviceHost, ap.poller.logger)

			results <- svcCheck.execute(checkCtx)
		}(check)
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	for result := range results {
		statuses = append(statuses, result)
	}

	return statuses
}

// ExecuteResults runs GetResults calls for services that need it and are due for polling.
func (ap *AgentPoller) ExecuteResults(ctx context.Context) []*proto.ServiceStatus {
	checkCtx, cancel := context.WithTimeout(ctx, ap.timeout)
	defer cancel()

	results := make(chan *proto.ServiceStatus, len(ap.resultsPollers))
	statuses := make([]*proto.ServiceStatus, 0, len(ap.resultsPollers))

	var wg sync.WaitGroup

	now := time.Now()

	ap.poller.logger.Debug().
		Str("agent", ap.name).
		Int("total_results_pollers", len(ap.resultsPollers)).
		Msg("ExecuteResults called")

	for _, resultsPoller := range ap.resultsPollers {
		timeSinceLastResults := now.Sub(resultsPoller.lastResults)
		shouldExecute := timeSinceLastResults >= resultsPoller.interval

		ap.poller.logger.Debug().
			Str("agent", ap.name).
			Str("service_name", resultsPoller.check.Name).
			Dur("time_since_last_results", timeSinceLastResults).
			Dur("interval", resultsPoller.interval).
			Bool("should_execute", shouldExecute).
			Msg("Results poller timing check")

		if shouldExecute {
			ap.poller.logger.Info().
				Str("agent", ap.name).
				Str("service_name", resultsPoller.check.Name).
				Msg("Executing results poller")

			wg.Add(1)

			go func(rp *ResultsPoller) {
				defer wg.Done()

				statusResult := rp.executeGetResults(checkCtx)
				if statusResult != nil {
					results <- statusResult
				}

				rp.lastResults = now
			}(resultsPoller)
		}
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	for result := range results {
		statuses = append(statuses, result)
	}

	return statuses
}

func newServiceCheck(
	client proto.AgentServiceClient,
	check Check,
	pollerID,
	agentName,
	kvStoreId,
	deviceIP,
	deviceHost string,
	logger logger.Logger,
) *ServiceCheck {
	return &ServiceCheck{
		client:     client,
		check:      check,
		pollerID:   pollerID,
		agentName:  agentName,
		deviceIP:   deviceIP,
		deviceHost: deviceHost,
		logger:     logger,
		kvStoreId:  kvStoreId,
	}
}

func (sc *ServiceCheck) execute(ctx context.Context) *proto.ServiceStatus {
	req := &proto.StatusRequest{
		ServiceName: sc.check.Name,
		ServiceType: sc.check.Type,
		AgentId:     sc.agentName,
		PollerId:    sc.pollerID,
		Details:     sc.check.Details,
	}

	if sc.check.Type == "port" {
		req.Port = sc.check.Port
	}

	sc.logger.Debug().
		Str("service_name", sc.check.Name).
		Str("service_type", sc.check.Type).
		Str("agent_name", sc.agentName).
		Str("poller_id", sc.pollerID).
		Msg("Executing service check")

	getStatus, err := sc.client.GetStatus(ctx, req)
	if err != nil {
		sc.logger.Error().Err(err).
			Str("service_name", sc.check.Name).
			Str("service_type", sc.check.Type).
			Str("agent_name", sc.agentName).
			Str("poller_id", sc.pollerID).
			Msg("Service check failed")

		msg := "Service check failed"

		message, err := json.Marshal(map[string]string{"error": msg})
		if err != nil {
			sc.logger.Warn().Err(err).Str("service_name", sc.check.Name).Msg("Failed to marshal error message, using fallback")

			message = []byte(msg)
		}
		message = enrichServiceMessageWithAddress(message, sc.check, sc.deviceIP, sc.deviceHost)

		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     message,
			ServiceType: sc.check.Type,
			AgentId:     sc.agentName,
			PollerId:    sc.pollerID,
			Source:      "getStatus",
			KvStoreId:   sc.kvStoreId,
		}
	}

	sc.logger.Debug().
		Str("service_name", sc.check.Name).
		Str("service_type", sc.check.Type).
		Str("agent_name", sc.agentName).
		Bool("available", getStatus.Available).
		Msg("Service check completed successfully")

	agentID := getStatus.AgentId
	if agentID == "" {
		agentID = sc.agentName
	}

	enriched := enrichServiceMessageWithAddress(getStatus.Message, sc.check, sc.deviceIP, sc.deviceHost)

	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    getStatus.Available,
		Message:      enriched,
		ServiceType:  sc.check.Type,
		ResponseTime: getStatus.ResponseTime,
		AgentId:      agentID,
		PollerId:     sc.pollerID,
		Source:       "getStatus",
		KvStoreId:    sc.kvStoreId,
	}
}

func enrichServiceMessageWithAddress(message []byte, check Check, deviceIP, deviceHost string) []byte {
	sanitizedIP := sanitizeTelemetryString(deviceIP)
	sanitizedHost := sanitizeTelemetryString(deviceHost)

	detailsHost := extractHostFromCheck(check)
	if sanitizedHost == "" {
		sanitizedHost = detailsHost
	}

	normalizedIP := pickBestIP(sanitizedIP, sanitizedHost, detailsHost)

	if normalizedIP == "" {
		return message
	}

	if sanitizedHost == "" {
		sanitizedHost = normalizedIP
	}

	return enrichPayloadWithHost(message, normalizedIP, sanitizedHost)
}

// sanitizeTelemetryString trims and removes control characters from telemetry-derived
// strings to reduce the risk of log/HTML injection when the data is rendered later.
const maxTelemetryStringLength = 512

func sanitizeTelemetryString(in string) string {
	trimmed := strings.TrimSpace(in)
	if len(trimmed) > maxTelemetryStringLength {
		trimmed = trimmed[:maxTelemetryStringLength]
	}

	builder := strings.Builder{}
	builder.Grow(len(trimmed))

	for _, r := range trimmed {
		if r < 0x20 && r != '\n' && r != '\r' && r != '\t' {
			continue
		}
		builder.WriteRune(r)
	}

	return builder.String()
}

func extractHostFromCheck(check Check) string {
	if check.Details == "" {
		return ""
	}

	candidate := sanitizeTelemetryString(check.Details)
	if candidate == "" {
		return ""
	}

	if host, _, err := net.SplitHostPort(candidate); err == nil && host != "" {
		return sanitizeTelemetryString(host)
	}

	return candidate
}

func pickBestIP(deviceIP, deviceHost, detailsHost string) string {
	candidates := []string{
		deviceIP,
		deviceHost,
		detailsHost,
	}

	for _, candidate := range candidates {
		cleaned := sanitizeTelemetryString(candidate)
		if cleaned == "" {
			continue
		}

		if parsed := net.ParseIP(cleaned); parsed != nil {
			if v4 := parsed.To4(); v4 != nil {
				return v4.String()
			}
			return parsed.String()
		}
	}

	return ""
}

func enrichPayloadWithHost(message []byte, ip, host string) []byte {
	payload := make(map[string]any)
	if len(message) > 0 {
		if err := json.Unmarshal(message, &payload); err != nil {
			payload = make(map[string]any)
		}
	}

	var statusNode map[string]any
	switch current := payload["status"].(type) {
	case map[string]any:
		statusNode = current
	case nil:
		statusNode = make(map[string]any)
	default:
		// Preserve original status text if present
		payload["status_text"] = current
		statusNode = make(map[string]any)
	}

	if ip != "" {
		statusNode["host_ip"] = ip
		statusNode["ip"] = ip
		payload["host_ip"] = ip
		payload["ip"] = ip
	}

	if host != "" {
		statusNode["host_name"] = host
		if _, exists := statusNode["hostname"]; !exists {
			statusNode["hostname"] = host
		}
		payload["host_name"] = host
		if _, exists := payload["hostname"]; !exists {
			payload["hostname"] = host
		}
	}

	payload["status"] = statusNode

	enriched, err := json.Marshal(payload)
	if err != nil {
		return message
	}

	return enriched
}
