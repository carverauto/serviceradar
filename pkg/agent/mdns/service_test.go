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

func TestDrainRecordsEmpty(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.Enabled = true

	svc, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.NoError(t, err)

	records := svc.DrainRecords()
	assert.Nil(t, records)
}

func TestDrainRecordsReturnsAndClears(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	cfg.Enabled = true

	svc, err := NewMdnsService(cfg, logger.NewTestLogger())
	require.NoError(t, err)

	// Manually add records to the buffer
	svc.recordsMu.Lock()
	svc.records = append(svc.records, MdnsRecordJSON{
		RecordType:   "A",
		Hostname:     "test.local.",
		ResolvedAddr: "192.168.1.1",
	})
	svc.records = append(svc.records, MdnsRecordJSON{
		RecordType:   "AAAA",
		Hostname:     "test2.local.",
		ResolvedAddr: "fe80::1",
	})
	svc.recordsMu.Unlock()

	records := svc.DrainRecords()
	require.Len(t, records, 2)
	assert.Equal(t, "A", records[0].RecordType)
	assert.Equal(t, "AAAA", records[1].RecordType)

	// Buffer should be empty now
	records2 := svc.DrainRecords()
	assert.Nil(t, records2)
}

func TestMaxBufferedRecordsDefault(t *testing.T) {
	t.Parallel()

	cfg := DefaultConfig()
	assert.Equal(t, 1000, cfg.MaxBufferedRecords)
}
