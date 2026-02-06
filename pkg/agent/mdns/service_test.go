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
	"testing"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewMdnsServiceValidConfig(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.Enabled = true

	svc, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.NoError(t, err)
	assert.NotNil(t, svc)
}

func TestNewMdnsServiceInvalidConfig(t *testing.T) {
	t.Parallel()

	cfg := &Config{} // empty config
	_, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.Error(t, err)
}

func TestNewMdnsServiceEmptyNATSUrl(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.NATSUrl = ""
	_, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.ErrorIs(t, err, ErrNATSURLEmpty)
}

func TestNewMdnsServiceEmptySubject(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.Subject = ""
	_, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.ErrorIs(t, err, ErrSubjectEmpty)
}

func TestConfigValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		modify  func(*Config)
		wantErr error
	}{
		{
			name:    "valid default config",
			modify:  func(_ *Config) {},
			wantErr: nil,
		},
		{
			name:    "empty listen_addr",
			modify:  func(c *Config) { c.ListenAddr = "" },
			wantErr: ErrListenAddrEmpty,
		},
		{
			name:    "empty nats_url",
			modify:  func(c *Config) { c.NATSUrl = "" },
			wantErr: ErrNATSURLEmpty,
		},
		{
			name:    "empty stream_name",
			modify:  func(c *Config) { c.StreamName = "" },
			wantErr: ErrStreamNameEmpty,
		},
		{
			name:    "empty subject",
			modify:  func(c *Config) { c.Subject = "" },
			wantErr: ErrSubjectEmpty,
		},
		{
			name:    "empty multicast_groups",
			modify:  func(c *Config) { c.MulticastGroups = nil },
			wantErr: ErrMulticastGroupsEmpty,
		},
		{
			name:    "zero dedup_ttl_secs",
			modify:  func(c *Config) { c.DedupTTLSecs = 0 },
			wantErr: ErrDedupTTLZero,
		},
		{
			name:    "zero dedup_max_entries",
			modify:  func(c *Config) { c.DedupMaxEntries = 0 },
			wantErr: ErrDedupMaxEntriesZero,
		},
		{
			name:    "zero dedup_cleanup_interval_secs",
			modify:  func(c *Config) { c.DedupCleanupIntervalSecs = 0 },
			wantErr: ErrDedupCleanupIntervalZero,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := DefaultConfig()
			tt.modify(cfg)
			err := cfg.Validate()
			if tt.wantErr != nil {
				require.ErrorIs(t, err, tt.wantErr)
			} else {
				require.NoError(t, err)
			}
		})
	}
}

func TestStreamSubjectsResolved(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	subjects := cfg.StreamSubjectsResolved()
	assert.Equal(t, []string{"discovery.raw.mdns"}, subjects)
}

func TestStreamSubjectsResolvedWithExtra(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.StreamSubjects = []string{"discovery.raw.mdns", "discovery.raw.mdns.processed"}
	subjects := cfg.StreamSubjectsResolved()
	assert.Contains(t, subjects, "discovery.raw.mdns")
	assert.Contains(t, subjects, "discovery.raw.mdns.processed")
}

func TestStreamSubjectsResolvedAddsSubject(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.StreamSubjects = []string{"other.subject"}
	subjects := cfg.StreamSubjectsResolved()
	assert.Contains(t, subjects, "discovery.raw.mdns")
	assert.Contains(t, subjects, "other.subject")
}
