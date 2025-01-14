package alerts

import "time"

const DiscordTemplate = `{
    "embeds": [{
        "title": "{{.alert.Title}}",
        "description": "{{.alert.Message}}",
        "color": {{if eq .alert.Level "error"}}15158332{{else if eq .alert.Level "warning"}}16776960{{else}}3447003{{end}},
        "timestamp": "{{.alert.Timestamp}}"
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
