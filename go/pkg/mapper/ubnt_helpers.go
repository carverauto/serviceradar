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
	"fmt"
	"strings"
)

func (e *DiscoveryEngine) unifiAPIsForJob(job *DiscoveryJob) []UniFiAPIConfig {
	filtered, selectors := selectNamedBaseURLConfigs(
		job,
		e.config.UniFiAPIs,
		"unifi_api_names",
		"unifi_api_urls",
		func(api UniFiAPIConfig) string { return api.Name },
		func(api UniFiAPIConfig) string { return api.BaseURL },
	)

	if len(filtered) == 0 && selectors != "" {
		e.logger.Warn().
			Str("job_id", job.ID).
			Str("job_name", job.Params.Options["mapper_job_name"]).
			Str("selectors", selectors).
			Msg("No UniFi API matched job selectors")
	}

	return filtered
}

func parseCSVSet(raw string, lower bool) map[string]bool {
	result := make(map[string]bool)

	for _, part := range strings.Split(raw, ",") {
		v := strings.TrimSpace(part)
		if v == "" {
			continue
		}

		if lower {
			v = strings.ToLower(v)
		}

		result[v] = true
	}

	return result
}

func normalizeURLKey(raw string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(raw)), "/")
}

func uniFiLinkDedupKey(link *TopologyLink, siteID string) string {
	if link == nil {
		return siteID + ":nil"
	}

	return fmt.Sprintf(
		"%s:%s:%s:%d:%s:%s:%s:%s:%s",
		siteID,
		link.Protocol,
		link.LocalDeviceID,
		link.LocalIfIndex,
		link.LocalIfName,
		link.LocalDeviceIP,
		link.NeighborMgmtAddr,
		NormalizeMAC(link.NeighborChassisID),
		link.NeighborPortID,
	)
}
