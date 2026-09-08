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

package endpointinventory

import (
	"fmt"
	"time"
)

func BuildCycloneDX(cfg Config, timestamp time.Time, osInfo OSInfo, packages []Package) CycloneDXBOM {
	components := make([]CycloneDXComponent, 0, len(packages))
	for _, pkg := range packages {
		component := CycloneDXComponent{
			Type:    "library",
			Name:    pkg.Name,
			Version: pkg.Version,
			PURL:    pkg.PURL,
			Properties: []CycloneDXProperty{
				{Name: "serviceradar:package_manager", Value: pkg.Manager},
			},
		}
		if pkg.Arch != "" {
			component.Properties = append(component.Properties, CycloneDXProperty{
				Name:  "serviceradar:architecture",
				Value: pkg.Arch,
			})
		}
		if len(pkg.CPEs) > 0 {
			component.CPE = pkg.CPEs[0]
		}
		components = append(components, component)
	}

	properties := []CycloneDXProperty{
		{Name: "serviceradar:schema_version", Value: SchemaVersion},
		{Name: "serviceradar:agent_id", Value: cfg.AgentID},
		{Name: "serviceradar:collection_cadence", Value: cfg.Cadence},
		{Name: "serviceradar:collect_paths", Value: fmt.Sprintf("%t", cfg.CollectPaths)},
		{Name: "serviceradar:collect_file_hashes", Value: fmt.Sprintf("%t", cfg.CollectFileHashes)},
		{Name: "serviceradar:redaction_paths", Value: redactionState(cfg.CollectPaths)},
		{Name: "serviceradar:redaction_file_hashes", Value: redactionState(cfg.CollectFileHashes)},
	}
	if osInfo.ID != "" {
		properties = append(properties, CycloneDXProperty{Name: "serviceradar:os_id", Value: osInfo.ID})
	}
	if osInfo.VersionID != "" {
		properties = append(properties, CycloneDXProperty{Name: "serviceradar:os_version_id", Value: osInfo.VersionID})
	}

	return CycloneDXBOM{
		BOMFormat:    CycloneDXFormat,
		SpecVersion:  CycloneDXSpecVersion,
		SerialNumber: fmt.Sprintf("urn:uuid:%s", newScanID()),
		Version:      1,
		Metadata: CycloneDXMetadata{
			Timestamp: timestamp,
			Tools: []CycloneDXTool{{
				Vendor: "Carver Automation",
				Name:   collectorName,
			}},
			Component: &CycloneDXComponent{
				Type:    "operating-system",
				Name:    firstNonEmpty(osInfo.PrettyName, osInfo.Name, osInfo.ID, "unknown"),
				Version: firstNonEmpty(osInfo.VersionID, osInfo.Version),
			},
			Properties: properties,
		},
		Components: components,
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}

	return ""
}
