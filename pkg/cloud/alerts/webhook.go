package alerts

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"text/template"
	"time"
)

// pkg/cloud/alerts/webhook.go

type WebhookConfig struct {
	Enabled  bool          `json:"enabled"`
	URL      string        `json:"url"`
	Headers  []Header      `json:"headers,omitempty"`  // Custom headers
	Template string        `json:"template,omitempty"` // Optional JSON template
	Cooldown time.Duration `json:"cooldown,omitempty"`
}

type Header struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type AlertLevel string

const (
	Info    AlertLevel = "info"
	Warning AlertLevel = "warning"
	Error   AlertLevel = "error"
)

type WebhookAlert struct {
	Level     AlertLevel     `json:"level"`
	Title     string         `json:"title"`
	Message   string         `json:"message"`
	Timestamp string         `json:"timestamp"`
	NodeID    string         `json:"node_id"`
	Details   map[string]any `json:"details,omitempty"`
}

type WebhookAlerter struct {
	config         WebhookConfig
	client         *http.Client
	lastAlertTimes map[string]time.Time
	mu             sync.RWMutex
}

func (w *WebhookConfig) UnmarshalJSON(data []byte) error {
	type Alias WebhookConfig
	aux := &struct {
		Cooldown string `json:"cooldown"`
		*Alias
	}{
		Alias: (*Alias)(w),
	}

	if err := json.Unmarshal(data, &aux); err != nil {
		return err
	}

	// Parse the cooldown duration
	if aux.Cooldown != "" {
		duration, err := time.ParseDuration(aux.Cooldown)
		if err != nil {
			return fmt.Errorf("invalid cooldown format: %w", err)
		}
		w.Cooldown = duration
	}

	return nil
}

func NewWebhookAlerter(config WebhookConfig) *WebhookAlerter {
	return &WebhookAlerter{
		config: config,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
		lastAlertTimes: make(map[string]time.Time),
	}
}

func (w *WebhookAlerter) Alert(alert WebhookAlert) error {
	if !w.config.Enabled {
		log.Printf("Webhook alerter disabled, skipping alert: %s", alert.Title)
		return nil
	}

	// Ensure timestamp is set
	if alert.Timestamp == "" {
		alert.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	log.Printf("Preparing to send alert: %s", alert.Title)

	var payload []byte
	var err error

	if w.config.Template != "" {
		log.Printf("Using custom template for alert")

		// Create template with escaping built in
		tmpl, err := template.New("webhook").Parse(w.config.Template)
		if err != nil {
			return fmt.Errorf("error parsing template: %w", err)
		}

		var buf bytes.Buffer
		if err := tmpl.Execute(&buf, map[string]interface{}{
			"alert": alert,
		}); err != nil {
			return fmt.Errorf("error executing template: %w", err)
		}

		payload = buf.Bytes()

		// Validate the JSON before sending
		var js json.RawMessage
		if err := json.Unmarshal(payload, &js); err != nil {
			return fmt.Errorf("template generated invalid JSON: %w\nPayload: %s", err, payload)
		}
	} else {
		payload, err = json.Marshal(alert)
		if err != nil {
			return fmt.Errorf("error marshaling alert: %w", err)
		}
	}

	log.Printf("Sending webhook request to: %s", w.config.URL)
	req, err := http.NewRequest("POST", w.config.URL, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("error creating request: %w", err)
	}

	// Set headers
	hasContentType := false
	for _, header := range w.config.Headers {
		if strings.ToLower(header.Key) == "content-type" {
			hasContentType = true
		}
		req.Header.Set(header.Key, header.Value)
	}

	if !hasContentType {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := w.client.Do(req)
	if err != nil {
		return fmt.Errorf("error sending webhook: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("webhook returned status %d: %s", resp.StatusCode, string(body))
	}

	log.Printf("Successfully sent alert: %s", alert.Title)
	return nil
}

// applyTemplate applies a custom JSON template for different webhook services
func (w *WebhookAlerter) applyTemplate(alert WebhookAlert) ([]byte, error) {
	data := map[string]interface{}{
		"alert":     alert,
		"timestamp": time.Now().Unix(),
	}

	tmpl, err := template.New("webhook").Parse(w.config.Template)
	if err != nil {
		return nil, fmt.Errorf("error parsing template: %w", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return nil, fmt.Errorf("error executing template: %w", err)
	}

	return buf.Bytes(), nil
}
