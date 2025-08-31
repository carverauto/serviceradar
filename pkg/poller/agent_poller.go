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
		name:    name,
		config:  filteredConfig,
		client:  client,
		timeout: defaultTimeout,
		poller:  poller,
	}

	for _, check := range config.Checks {
		if check.ResultsInterval != nil {
			// Checks with results_interval go to results pollers
			resultsPoller := &ResultsPoller{
				client:    client,
				check:     check,
				pollerID:  poller.config.PollerID,
				agentName: name,
				interval:  time.Duration(*check.ResultsInterval),
				poller:    poller,
				logger:    poller.logger,
				kvStoreId: poller.config.KVAddress,
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

			svcCheck := newServiceCheck(ap.client, check, ap.poller.config.PollerID, ap.name, ap.poller.config.KVAddress, ap.poller.logger)

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

func newServiceCheck(client proto.AgentServiceClient, check Check, pollerID, agentName, kvStoreId string, logger logger.Logger) *ServiceCheck {
	return &ServiceCheck{
		client:    client,
		check:     check,
		pollerID:  pollerID,
		agentName: agentName,
		logger:    logger,
		kvStoreId: kvStoreId,
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

		return &proto.ServiceStatus{
			ServiceName: sc.check.Name,
			Available:   false,
			Message:     message,
			ServiceType: sc.check.Type,
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

	return &proto.ServiceStatus{
		ServiceName:  sc.check.Name,
		Available:    getStatus.Available,
		Message:      getStatus.Message,
		ServiceType:  sc.check.Type,
		ResponseTime: getStatus.ResponseTime,
		AgentId:      getStatus.AgentId,
		PollerId:     sc.pollerID,
		Source:       "getStatus",
		KvStoreId:    sc.kvStoreId,
	}
}
