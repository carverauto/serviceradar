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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/mapper"
)

type gatewayMapperPayload struct {
	Mapper json.RawMessage `json:"mapper"`
}

type gatewayMapperConfig struct {
	Workers         int               `json:"workers"`
	Timeout         string            `json:"timeout"`
	Retries         int               `json:"retries"`
	MaxActiveJobs   int               `json:"max_active_jobs"`
	ResultRetention string            `json:"result_retention"`
	Seeds           []string          `json:"seeds"`
	Credentials     []mapperCredSpec  `json:"credentials"`
	UniFiAPIs       []mapperUnifiSpec `json:"unifi_apis"`
	ScheduledJobs   []mapperJobSpec   `json:"scheduled_jobs"`
	ConfigHash      string            `json:"config_hash"`
}

type mapperCredSpec struct {
	Targets         []string `json:"targets"`
	Version         string   `json:"version"`
	Community       string   `json:"community"`
	Username        string   `json:"username"`
	AuthProtocol    string   `json:"auth_protocol"`
	AuthPassword    string   `json:"auth_password"`
	PrivacyProtocol string   `json:"privacy_protocol"`
	PrivacyPassword string   `json:"privacy_password"`
}

type mapperUnifiSpec struct {
	BaseURL            string `json:"base_url"`
	APIKey             string `json:"api_key"`
	Name               string `json:"name"`
	InsecureSkipVerify bool   `json:"insecure_skip_verify"`
}

type mapperJobSpec struct {
	Name        string                 `json:"name"`
	Interval    string                 `json:"interval"`
	Enabled     bool                   `json:"enabled"`
	Seeds       []string               `json:"seeds"`
	Type        string                 `json:"type"`
	Credentials map[string]interface{} `json:"credentials"`
	Concurrency int                    `json:"concurrency"`
	Timeout     string                 `json:"timeout"`
	Retries     int                    `json:"retries"`
	Options     map[string]string      `json:"options"`
}

var errServerConfigRequired = errors.New("server config required")

func parseGatewayMapperConfig(configJSON []byte) (*gatewayMapperConfig, error) {
	if len(configJSON) == 0 {
		return nil, nil
	}

	var payload gatewayMapperPayload
	if err := json.Unmarshal(configJSON, &payload); err != nil {
		return nil, fmt.Errorf("decode gateway payload: %w", err)
	}

	if len(payload.Mapper) == 0 {
		return nil, nil
	}

	var cfg gatewayMapperConfig
	if err := json.Unmarshal(payload.Mapper, &cfg); err != nil {
		return nil, fmt.Errorf("decode mapper payload: %w", err)
	}

	if cfg.ConfigHash == "" {
		cfg.ConfigHash = mapperConfigHash(payload.Mapper)
	}

	return &cfg, nil
}

func mapperConfigHash(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}

	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:8])
}

func buildMapperEngineConfig(cfg *gatewayMapperConfig, serverCfg *ServerConfig, log logger.Logger) (*mapper.Config, error) {
	if cfg == nil {
		return nil, errMapperConfigRequired
	}

	if serverCfg == nil {
		return nil, errServerConfigRequired
	}

	parsed := &mapper.Config{
		Workers:         cfg.Workers,
		MaxActiveJobs:   cfg.MaxActiveJobs,
		Retries:         cfg.Retries,
		Seeds:           cfg.Seeds,
		Credentials:     convertMapperCreds(cfg.Credentials),
		UniFiAPIs:       convertMapperUnifi(cfg.UniFiAPIs),
		ScheduledJobs:   convertMapperJobs(cfg.ScheduledJobs, log),
		ResultRetention: parseMapperDuration(cfg.ResultRetention, 24*time.Hour, log),
		Timeout:         parseMapperDuration(cfg.Timeout, 30*time.Second, log),
		StreamConfig: mapper.StreamConfig{
			AgentID:   serverCfg.AgentID,
			GatewayID: serverCfg.AgentID,
			Partition: serverCfg.Partition,
		},
	}

	if parsed.Workers <= 0 {
		parsed.Workers = 20
	}
	if parsed.MaxActiveJobs <= 0 {
		parsed.MaxActiveJobs = 100
	}

	return parsed, nil
}

func parseMapperDuration(raw string, fallback time.Duration, log logger.Logger) time.Duration {
	if raw == "" {
		return fallback
	}

	parsed, err := time.ParseDuration(raw)
	if err != nil {
		log.Warn().Err(err).Str("duration", raw).Msg("Invalid mapper duration, using default")
		return fallback
	}

	return parsed
}

func convertMapperCreds(creds []mapperCredSpec) []mapper.SNMPCredentialConfig {
	if len(creds) == 0 {
		return nil
	}

	out := make([]mapper.SNMPCredentialConfig, 0, len(creds))
	for _, cred := range creds {
		out = append(out, mapper.SNMPCredentialConfig{
			Targets:         cred.Targets,
			Version:         mapper.SNMPVersion(cred.Version),
			Community:       cred.Community,
			Username:        cred.Username,
			AuthProtocol:    cred.AuthProtocol,
			AuthPassword:    cred.AuthPassword,
			PrivacyProtocol: cred.PrivacyProtocol,
			PrivacyPassword: cred.PrivacyPassword,
		})
	}

	return out
}

func convertMapperUnifi(controllers []mapperUnifiSpec) []mapper.UniFiAPIConfig {
	if len(controllers) == 0 {
		return nil
	}

	out := make([]mapper.UniFiAPIConfig, 0, len(controllers))
	for _, controller := range controllers {
		out = append(out, mapper.UniFiAPIConfig{
			BaseURL:            controller.BaseURL,
			APIKey:             controller.APIKey,
			Name:               controller.Name,
			InsecureSkipVerify: controller.InsecureSkipVerify,
		})
	}

	return out
}

func convertMapperJobs(jobs []mapperJobSpec, log logger.Logger) []*mapper.ScheduledJob {
	if len(jobs) == 0 {
		return nil
	}

	out := make([]*mapper.ScheduledJob, 0, len(jobs))
	for _, job := range jobs {
		creds := parseMapperJobCreds(job, log)

		out = append(out, &mapper.ScheduledJob{
			Name:        job.Name,
			Interval:    job.Interval,
			Enabled:     job.Enabled,
			Seeds:       job.Seeds,
			Type:        job.Type,
			Credentials: creds,
			Concurrency: job.Concurrency,
			Timeout:     job.Timeout,
			Retries:     job.Retries,
			Options:     job.Options,
		})
	}

	return out
}

func parseMapperJobCreds(job mapperJobSpec, log logger.Logger) mapper.SNMPCredentials {
	if job.Credentials == nil {
		return mapper.SNMPCredentials{}
	}

	raw, err := json.Marshal(job.Credentials)
	if err != nil {
		log.Warn().Err(err).Str("job", job.Name).Msg("Failed to marshal mapper credentials")
		return mapper.SNMPCredentials{}
	}

	var parsed mapperCredSpec
	if err := json.Unmarshal(raw, &parsed); err != nil {
		log.Warn().Err(err).Str("job", job.Name).Msg("Failed to decode mapper credentials")
		return mapper.SNMPCredentials{}
	}

	return mapper.SNMPCredentials{
		Version:         mapper.SNMPVersion(parsed.Version),
		Community:       parsed.Community,
		Username:        parsed.Username,
		AuthProtocol:    parsed.AuthProtocol,
		AuthPassword:    parsed.AuthPassword,
		PrivacyProtocol: parsed.PrivacyProtocol,
		PrivacyPassword: parsed.PrivacyPassword,
	}
}
