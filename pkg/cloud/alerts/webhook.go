package alerts

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"text/template"
	"time"
)

var (
	errWebhookDisabled   = errors.New("webhook alerter is disabled")
	ErrWebhookCooldown   = errors.New("alert is within cooldown period")
	errInvalidJSON       = errors.New("invalid JSON generated")
	errWebhookStatus     = errors.New("webhook returned non-200 status")
	errTemplateParse     = errors.New("template parsing failed")
	errTemplateExecution = errors.New("template execution failed")
)

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
	Level       AlertLevel     `json:"level"`
	Title       string         `json:"title"`
	Message     string         `json:"message"`
	Timestamp   string         `json:"timestamp"`
	NodeID      string         `json:"node_id"`
	ServiceName string         `json:"service_name,omitempty"`
	Details     map[string]any `json:"details,omitempty"`
}

// AlertKey combines nodeID and title to make a unique key for cooldown tracking.
type AlertKey struct {
	NodeID      string
	Title       string
	ServiceName string
}

type WebhookAlerter struct {
	config         WebhookConfig
	client         *http.Client
	LastAlertTimes map[AlertKey]time.Time
	mu             sync.RWMutex
	bufferPool     *sync.Pool
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
		LastAlertTimes: make(map[AlertKey]time.Time),
		bufferPool: &sync.Pool{
			New: func() interface{} {
				return new(bytes.Buffer)
			},
		},
	}
}

func (w *WebhookAlerter) IsEnabled() bool {
	return w.config.Enabled
}

func (w *WebhookAlerter) getTemplateFuncs() template.FuncMap {
	return template.FuncMap{
		"json": func(v interface{}) (string, error) {
			buf := w.bufferPool.Get().(*bytes.Buffer)
			buf.Reset()
			defer w.bufferPool.Put(buf)

			enc := json.NewEncoder(buf)
			if err := enc.Encode(v); err != nil {
				return "", fmt.Errorf("JSON marshaling failed: %w", err)
			}

			return buf.String(), nil
		},
	}
}

// Alert sends an alert through the webhook.
func (w *WebhookAlerter) Alert(ctx context.Context, alert *WebhookAlert) error {
	if !w.IsEnabled() {
		log.Printf("Webhook alerter disabled, skipping alert: %s", alert.Title)
		return errWebhookDisabled
	}

	if err := w.CheckCooldown(alert.NodeID, alert.Title, alert.ServiceName); err != nil {
		return err
	}

	if err := w.ensureTimestamp(alert); err != nil {
		return err
	}

	payload, err := w.preparePayload(alert)
	if err != nil {
		return fmt.Errorf("failed to prepare payload: %w", err)
	}

	return w.sendRequest(ctx, payload)
}

// CheckCooldown checks if an alert is within its cooldown period.
func (w *WebhookAlerter) CheckCooldown(nodeID, alertTitle, serviceName string) error {
	if w.config.Cooldown <= 0 {
		return nil
	}

	w.mu.Lock()
	defer w.mu.Unlock()

	key := AlertKey{NodeID: nodeID, Title: alertTitle, ServiceName: serviceName}

	lastAlertTime, exists := w.LastAlertTimes[key]
	if exists && time.Since(lastAlertTime) < w.config.Cooldown {
		log.Printf("Alert '%s' for node '%s' is within cooldown period, skipping", alertTitle, nodeID)

		return ErrWebhookCooldown
	}

	w.LastAlertTimes[key] = time.Now()

	return nil
}

func (*WebhookAlerter) ensureTimestamp(alert *WebhookAlert) error {
	if alert.Timestamp == "" {
		alert.Timestamp = time.Now().UTC().Format(time.RFC3339)
	}

	return nil
}

func (w *WebhookAlerter) preparePayload(alert *WebhookAlert) ([]byte, error) {
	if w.config.Template == "" {
		buf := w.bufferPool.Get().(*bytes.Buffer)
		buf.Reset()
		defer w.bufferPool.Put(buf)

		enc := json.NewEncoder(buf)
		if err := enc.Encode(alert); err != nil {
			return nil, fmt.Errorf("failed to marshal alert: %w", err)
		}

		return append([]byte(nil), buf.Bytes()...), nil
	}

	return w.executeTemplate(alert)
}

func (w *WebhookAlerter) executeTemplate(alert *WebhookAlert) ([]byte, error) {
	tmpl, err := template.New("webhook").
		Funcs(w.getTemplateFuncs()).
		Parse(w.config.Template)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", errTemplateParse, err)
	}

	buf := w.bufferPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer w.bufferPool.Put(buf)

	if err := tmpl.Execute(buf, map[string]interface{}{
		"alert": alert,
	}); err != nil {
		return nil, fmt.Errorf("%w: %w", errTemplateExecution, err)
	}

	if !json.Valid(buf.Bytes()) {
		return nil, errInvalidJSON
	}

	return append([]byte(nil), buf.Bytes()...), nil
}

func (w *WebhookAlerter) sendRequest(ctx context.Context, payload []byte) error {
	buf := w.bufferPool.Get().(*bytes.Buffer)
	buf.Reset()
	defer w.bufferPool.Put(buf)

	buf.Write(payload)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.config.URL, buf)
	if err != nil {
		return fmt.Errorf("failed to create request: %w", err)
	}

	w.setHeaders(req)

	resp, err := w.client.Do(req) //nolint:bodyclose // Response body is closed later
	if err != nil {
		return fmt.Errorf("failed to send webhook: %w", err)
	}
	defer func(Body io.ReadCloser) {
		err := Body.Close()
		if err != nil {
			log.Printf("failed to close response body: %v", err)
		}
	}(resp.Body)

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errBuf := w.bufferPool.Get().(*bytes.Buffer)
		errBuf.Reset()
		defer w.bufferPool.Put(errBuf)

		_, _ = io.Copy(errBuf, resp.Body)

		return fmt.Errorf("%w: status=%d body=%s", errWebhookStatus, resp.StatusCode, errBuf.String())
	}

	return nil
}

func (w *WebhookAlerter) setHeaders(req *http.Request) {
	hasContentType := false

	for _, header := range w.config.Headers {
		if strings.EqualFold(header.Key, "content-type") {
			hasContentType = true
		}

		req.Header.Set(header.Key, header.Value)
	}

	if !hasContentType {
		req.Header.Set("Content-Type", "application/json")
	}
}
