package alerts

import "time"

// Discord colors (for reference)
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
