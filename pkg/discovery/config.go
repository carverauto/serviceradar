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

package discovery

import (
	"context"
	"fmt"

	"github.com/carverauto/serviceradar/pkg/checker/snmp"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/models"
)

// LoadConfig loads the discovery configuration from a file or KV store.
func LoadConfig(ctx context.Context, path string, kvStore models.KVStore) (*models.DiscoveryConfig, error) {
	cfgLoader := config.NewConfig()
	if kvStore != nil {
		cfgLoader.SetKVStore(kvStore)
	}

	var cfg models.DiscoveryConfig
	if err := cfgLoader.LoadAndValidate(ctx, path, &cfg); err != nil {
		return nil, fmt.Errorf("failed to load config from %s: %w", path, err)
	}

	// Set default OIDs if not specified
	if len(cfg.OIDs) == 0 {
		cfg.OIDs = map[string]string{
			"sysDescr":           "1.3.6.1.2.1.1.1.0",
			"sysObjectID":        "1.3.6.1.2.1.1.2.0",
			"sysName":            "1.3.6.1.2.1.1.5.0",
			"sysUpTime":          "1.3.6.1.2.1.1.3.0",
			"sysContact":         "1.3.6.1.2.1.1.4.0",
			"sysLocation":        "1.3.6.1.2.1.1.6.0",
			"ifIndex":            "1.3.6.1.2.1.2.2.1.1",
			"ifDescr":            "1.3.6.1.2.1.2.2.1.2",
			"ifName":             "1.3.6.1.2.1.31.1.1.1.1",
			"ifAlias":            "1.3.6.1.2.1.31.1.1.1.18",
			"ifSpeed":            "1.3.6.1.2.1.2.2.1.5",
			"ifPhysAddress":      "1.3.6.1.2.1.2.2.1.6",
			"ifAdminStatus":      "1.3.6.1.2.1.2.2.1.7",
			"ifOperStatus":       "1.3.6.1.2.1.2.2.1.8",
			"ipAdEntIfIndex":     "1.3.6.1.2.1.4.20.1.2",
			"lldpRemChassisId":   "1.0.8802.1.1.2.1.4.1.1.5",
			"lldpRemPortId":      "1.0.8802.1.1.2.1.4.1.1.7",
			"lldpRemPortDesc":    "1.0.8802.1.1.2.1.4.1.1.8",
			"lldpRemSysName":     "1.0.8802.1.1.2.1.4.1.1.9",
			"lldpRemManAddr":     "1.0.8802.1.1.2.1.4.2.1.3",
			"cdpCacheAddress":    "1.3.6.1.4.1.9.9.23.1.2.1.1.4",
			"cdpCacheDeviceId":   "1.3.6.1.4.1.9.9.23.1.2.1.1.6",
			"cdpCacheDevicePort": "1.3.6.1.4.1.9.9.23.1.2.1.1.7",
		}
	}

	// Validate credentials
	for i, cred := range cfg.Credentials {
		if cred.Version == "" {
			cred.Version = snmp.Version2c
		}
		if cred.Community == "" {
			cred.Community = "public"
		}
		if cred.Port == 0 {
			cred.Port = 161
		}
		cfg.Credentials[i] = cred
	}

	return &cfg, nil
}
