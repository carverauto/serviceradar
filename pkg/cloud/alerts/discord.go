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

package alerts

import "time"

const (
	DiscordColorRed    = 15158332 // Error
	DiscordColorYellow = 16776960 // Warning
	DiscordColorBlue   = 3447003  // Info
)

const DiscordTemplate = `{
  "embeds": [{
    "title": {{json .alert.Title}},
    "description": {{json .alert.Message}},
    "color": {{if eq .alert.Level "error"}}15158332{{else if eq .alert.Level "warning"}}16776960{{else}}3447003{{end}},
    "timestamp": {{json .alert.Timestamp}},
    "fields": [
      {
        "name": "Node ID",
        "value": {{json .alert.NodeID}},
        "inline": true
      }
      {{range $key, $value := .alert.Details}},
      {
        "name": {{json $key}},
        "value": {{json $value}},
        "inline": true
      }
      {{end}}
    ]
  }]
}`

func NewDiscordWebhook(webhookURL string, cooldown time.Duration) *WebhookAlerter {
	return NewWebhookAlerter(WebhookConfig{
		Enabled:  true,
		URL:      webhookURL,
		Template: DiscordTemplate,
		Cooldown: cooldown,
	})
}
