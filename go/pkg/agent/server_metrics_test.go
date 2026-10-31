/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 */

package agent

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestServerWritePrometheusMetricsIncludesBannerGrabStats(t *testing.T) {
	server := &Server{
		services: []Service{
			&bannerGrabMetricsService{stats: &models.BannerGrabStats{
				CandidatesTotal:      10,
				ProbesTotal:          7,
				InFlight:             2,
				QueueDepth:           3,
				MatchBatchesTotal:    4,
				MatchBatchBytesTotal: 2048,
				BannerBytesTotal:     1024,
				SkippedFreshTotal:    5,
				SkippedBackoffTotal:  6,
				MatchesTotal:         8,
				EmptyResponseTotal:   9,
				ConnectionResetTotal: 11,
				TimeoutTotal:         12,
				ErrorsTotal:          13,
			}},
		},
	}

	server.deliveryTelemetry.flowAttributionForwarded.Add(7)
	server.deliveryTelemetry.flowAttributionQuarantined.Add(1)
	server.deliveryTelemetry.recordPoisonDrop(retainedSourcePlugin, poisonReasonInvalidArgument, 2, 512)

	var out bytes.Buffer
	if err := server.WritePrometheusMetrics(&out); err != nil {
		t.Fatalf("WritePrometheusMetrics() error = %v", err)
	}

	metrics := out.String()
	for _, want := range []string{
		"# TYPE sweep_banner_grab_candidates_total counter\nsweep_banner_grab_candidates_total 10\n",
		"# TYPE sweep_banner_grab_inflight gauge\nsweep_banner_grab_inflight 2\n",
		"# TYPE sweep_banner_grab_match_batch_bytes_total counter\nsweep_banner_grab_match_batch_bytes_total 2048\n",
		"# TYPE sweep_banner_grab_bytes_received_total counter\nsweep_banner_grab_bytes_received_total 1024\n",
		"# TYPE sweep_banner_grab_timeout_total counter\nsweep_banner_grab_timeout_total 12\n",
		"# TYPE sweep_banner_grab_errors_total counter\nsweep_banner_grab_errors_total 13\n",
		"# TYPE agent_flow_attribution_events_forwarded_total counter\nagent_flow_attribution_events_forwarded_total 7\n",
		"# TYPE agent_flow_attribution_events_quarantined_total counter\nagent_flow_attribution_events_quarantined_total 1\n",
		"# TYPE agent_retained_poison_dropped_items_total counter\n",
		"# TYPE agent_retained_poison_dropped_bytes_total counter\n",
		"agent_retained_poison_dropped_items_total{source=\"plugin-result\",reason=\"invalid_argument\"} 2\n",
		"agent_retained_poison_dropped_bytes_total{source=\"plugin-result\",reason=\"invalid_argument\"} 512\n",
	} {
		if !strings.Contains(metrics, want) {
			t.Fatalf("metrics missing %q in:\n%s", want, metrics)
		}
	}
	if strings.Contains(metrics, "agent_edge_spool_") {
		t.Fatalf("edge spool metrics rendered without a sampler:\n%s", metrics)
	}
}

func TestServerWritePrometheusMetricsIncludesEdgeSpoolSample(t *testing.T) {
	server := &Server{}
	server.SetEdgeSpoolSampler(func(time.Time) (uint64, time.Duration, bool, bool) {
		return 4096, 125 * time.Second, true, true
	})

	var out bytes.Buffer
	if err := server.WritePrometheusMetrics(&out); err != nil {
		t.Fatalf("WritePrometheusMetrics() error = %v", err)
	}
	metrics := out.String()
	for _, want := range []string{
		"# TYPE agent_edge_spool_unresolved_bytes gauge\nagent_edge_spool_unresolved_bytes 4096\n",
		"# TYPE agent_edge_spool_oldest_unresolved_age_seconds gauge\nagent_edge_spool_oldest_unresolved_age_seconds 125\n",
	} {
		if !strings.Contains(metrics, want) {
			t.Fatalf("metrics missing %q in:\n%s", want, metrics)
		}
	}

	server.SetEdgeSpoolSampler(func(time.Time) (uint64, time.Duration, bool, bool) {
		return 12, 0, false, true
	})
	out.Reset()
	if err := server.WritePrometheusMetrics(&out); err != nil {
		t.Fatalf("WritePrometheusMetrics() error = %v", err)
	}
	metrics = out.String()
	if !strings.Contains(metrics, "agent_edge_spool_unresolved_bytes 12\n") {
		t.Fatalf("bytes missing in:\n%s", metrics)
	}
	if strings.Contains(metrics, "agent_edge_spool_oldest_unresolved_age_seconds") {
		t.Fatalf("age rendered without a UUIDv7 timestamp:\n%s", metrics)
	}

	server.SetEdgeSpoolSampler(func(time.Time) (uint64, time.Duration, bool, bool) {
		return 99, 10 * time.Second, true, false
	})
	out.Reset()
	if err := server.WritePrometheusMetrics(&out); err != nil {
		t.Fatalf("WritePrometheusMetrics() error = %v", err)
	}
	if strings.Contains(out.String(), "agent_edge_spool_") {
		t.Fatalf("failed sample rendered metrics:\n%s", out.String())
	}
}

type bannerGrabMetricsService struct {
	stats *models.BannerGrabStats
}

func (*bannerGrabMetricsService) Start(context.Context) error {
	return nil
}

func (*bannerGrabMetricsService) Stop(context.Context) error {
	return nil
}

func (*bannerGrabMetricsService) Name() string {
	return "banner-grab-metrics-test"
}

func (*bannerGrabMetricsService) UpdateConfig(*models.Config) error {
	return nil
}

func (s *bannerGrabMetricsService) GetBannerGrabStats() *models.BannerGrabStats {
	return s.stats
}
