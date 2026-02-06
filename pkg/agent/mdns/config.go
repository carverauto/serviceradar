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

package mdns

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"

	"github.com/carverauto/serviceradar/pkg/models"
)

// Config holds configuration for the mDNS collector service.
type Config struct {
	Enabled                  bool                   `json:"enabled"`
	ListenAddr               string                 `json:"listen_addr"`
	BufferSize               int                    `json:"buffer_size"`
	MulticastGroups          []string               `json:"multicast_groups"`
	ListenInterface          string                 `json:"listen_interface,omitempty"`
	NATSUrl                  string                 `json:"nats_url"`
	NATSCredsFile            string                 `json:"nats_creds_file,omitempty"`
	StreamName               string                 `json:"stream_name"`
	Subject                  string                 `json:"subject"`
	StreamSubjects           []string               `json:"stream_subjects,omitempty"`
	StreamMaxBytes           int64                  `json:"stream_max_bytes"`
	ChannelSize              int                    `json:"channel_size"`
	BatchSize                int                    `json:"batch_size"`
	PublishTimeoutMs         int                    `json:"publish_timeout_ms"`
	DedupTTLSecs             int                    `json:"dedup_ttl_secs"`
	DedupMaxEntries          int                    `json:"dedup_max_entries"`
	DedupCleanupIntervalSecs int                    `json:"dedup_cleanup_interval_secs"`
	Security                 *models.SecurityConfig `json:"security,omitempty"`
}

// DefaultConfig returns a Config with sensible defaults (disabled).
func DefaultConfig() *Config {
	return &Config{
		Enabled:                  false,
		ListenAddr:               "0.0.0.0:5353",
		BufferSize:               65536,
		MulticastGroups:          []string{"224.0.0.251"},
		NATSUrl:                  "nats://localhost:4222",
		StreamName:               "DISCOVERY",
		Subject:                  "discovery.raw.mdns",
		StreamMaxBytes:           10 * 1024 * 1024 * 1024,
		ChannelSize:              10000,
		BatchSize:                100,
		PublishTimeoutMs:         5000,
		DedupTTLSecs:             300,
		DedupMaxEntries:          100000,
		DedupCleanupIntervalSecs: 60,
	}
}

// Validate checks that the config has all required fields.
func (c *Config) Validate() error {
	if c.ListenAddr == "" {
		return ErrListenAddrEmpty
	}
	if c.NATSUrl == "" {
		return ErrNATSURLEmpty
	}
	if c.StreamName == "" {
		return ErrStreamNameEmpty
	}
	if c.Subject == "" {
		return ErrSubjectEmpty
	}
	if len(c.MulticastGroups) == 0 {
		return ErrMulticastGroupsEmpty
	}
	if c.DedupTTLSecs <= 0 {
		return ErrDedupTTLZero
	}
	if c.DedupMaxEntries <= 0 {
		return ErrDedupMaxEntriesZero
	}
	if c.DedupCleanupIntervalSecs <= 0 {
		return ErrDedupCleanupIntervalZero
	}
	return nil
}

// StreamSubjectsResolved returns the list of subjects the stream should cover,
// ensuring the publish subject is always included.
func (c *Config) StreamSubjectsResolved() []string {
	var subjects []string
	if len(c.StreamSubjects) > 0 {
		subjects = append(subjects, c.StreamSubjects...)
	} else {
		subjects = []string{c.Subject}
	}

	found := false
	for _, s := range subjects {
		if s == c.Subject {
			found = true
			break
		}
	}
	if !found {
		subjects = append(subjects, c.Subject)
	}

	sort.Strings(subjects)
	return subjects
}

// LoadConfigFromFile reads and parses a Config from a JSON file.
func LoadConfigFromFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	return &config, nil
}
