package core

import (
	"context"
	"fmt"
	"github.com/carverauto/serviceradar/pkg/core/alerts"
	"log"
	"time"
)

func (s *Server) sendAlert(ctx context.Context, alert *alerts.WebhookAlert) error {
	var errs []error

	log.Printf("Sending alert: %s", alert.Message)

	for _, webhook := range s.webhooks {
		if err := webhook.Alert(ctx, alert); err != nil {
			errs = append(errs, err)
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("%w: %v", errFailedToSendAlerts, errs)
	}

	return nil
}

func (s *Server) sendStartupNotification(ctx context.Context) error {
	if len(s.webhooks) == 0 {
		return nil
	}

	alert := &alerts.WebhookAlert{
		Level:     alerts.Info,
		Title:     "Core Service Started",
		Message:   fmt.Sprintf("ServiceRadar core service initialized at %s", time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		PollerID:  "core",
		Details: map[string]any{
			"version":  "1.0.36",
			"hostname": getHostname(),
		},
	}

	return s.sendAlert(ctx, alert)
}

func (s *Server) sendShutdownNotification(ctx context.Context) error {
	if len(s.webhooks) == 0 {
		return nil
	}

	alert := &alerts.WebhookAlert{
		Level: alerts.Warning,
		Title: "Core Service Stopping",
		Message: fmt.Sprintf("ServiceRadar core service shutting down at %s",
			time.Now().Format(time.RFC3339)),
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		PollerID:  "core",
		Details: map[string]any{
			"hostname": getHostname(),
		},
	}

	return s.sendAlert(ctx, alert)
}
