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

func (p *PushLoop) publishAddonMetricFeed(source string, payload []byte) {
	if p == nil || p.server == nil || len(payload) == 0 {
		return
	}

	p.server.mu.RLock()
	manager := p.server.addonManager
	p.server.mu.RUnlock()
	if manager == nil {
		return
	}

	if accepted := manager.PublishMetricFeed(source, payload); accepted > 0 {
		p.logger.Debug().
			Str("source", source).
			Int("addons", accepted).
			Int("payload_bytes", len(payload)).
			Msg("Published metric batch to add-on feed")
	}
}
