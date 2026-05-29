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

	"github.com/carverauto/serviceradar/go/pkg/models"
)

func TestServerWritePrometheusMetricsIncludesBannerGrabStats(t *testing.T) {
	t.Parallel()

	server := &Server{
		services: []Service{
			&bannerGrabMetricsService{stats: &models.BannerGrabStats{
				CandidatesTotal:      10,
				ProbesTotal:          7,
				InFlight:             2,
				QueueDepth:           3,
				MatchBatchesTotal:    4,
				MatchBatchBytesTotal: 2048,
				SkippedFreshTotal:    5,
				SkippedBackoffTotal:  6,
				MatchesTotal:         8,
				EmptyResponseTotal:   9,
				ConnectionResetTotal: 11,
				TimeoutTotal:         12,
			}},
		},
	}

	var out bytes.Buffer
	if err := server.WritePrometheusMetrics(&out); err != nil {
		t.Fatalf("WritePrometheusMetrics() error = %v", err)
	}

	metrics := out.String()
	for _, want := range []string{
		"# TYPE sweep_banner_grab_candidates_total counter\nsweep_banner_grab_candidates_total 10\n",
		"# TYPE sweep_banner_grab_inflight gauge\nsweep_banner_grab_inflight 2\n",
		"# TYPE sweep_banner_grab_match_batch_bytes_total counter\nsweep_banner_grab_match_batch_bytes_total 2048\n",
		"# TYPE sweep_banner_grab_timeout_total counter\nsweep_banner_grab_timeout_total 12\n",
	} {
		if !strings.Contains(metrics, want) {
			t.Fatalf("metrics missing %q in:\n%s", want, metrics)
		}
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
