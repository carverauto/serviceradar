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
		return nil
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	log.Printf("Processing alert: Level=%s, Title=%s, NodeID=%s",
		alert.Level, alert.Title, alert.NodeID)

	// Check cooldown
	if lastAlert, ok := w.lastAlertTimes[alert.NodeID]; ok {
		if time.Since(lastAlert) < w.config.Cooldown {
			return nil
		}
	}

	// Set timestamp if not provided
	if alert.Timestamp == "" {
		alert.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	var payload []byte
	var err error

	if w.config.Template != "" {
		// Use custom template if provided
		payload, err = w.applyTemplate(alert)
	} else {
		// Use default JSON format
		payload, err = json.Marshal(alert)
	}

	if err != nil {
		return fmt.Errorf("error preparing webhook payload: %w", err)
	}

	req, err := http.NewRequest("POST", w.config.URL, bytes.NewBuffer(payload))
	if err != nil {
		return fmt.Errorf("error creating request: %w", err)
	}

	// Set default content type if not specified in headers
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

	w.lastAlertTimes[alert.NodeID] = time.Now()
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
