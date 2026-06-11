/*
 * Copyright 2026 Carver Automation Corporation.
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
	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources"
	"github.com/carverauto/serviceradar/go/pkg/agent/syncsources/armis"
)

// This file is the single wiring point between the integration-agnostic sync
// runtime and concrete sync-source drivers. To add a new integration (for
// example NetBox or UniFi), implement syncsources.SourceDriver in a new
// subpackage under go/pkg/agent/syncsources/ and register it here. The sync
// runtime itself never references individual integrations.
//
//nolint:gochecknoinits // This package is the explicit sync driver registration boundary.
func init() {
	syncsources.Register(armis.SourceType, armis.NewDriver)
}
