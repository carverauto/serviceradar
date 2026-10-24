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

package agent

import (
	"context"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/go/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

const legacySweepPayload = `{
	"sweep": {
		"groups": [
			{
				"id": "sg-1",
				"sweep_group_id": "sg-1",
				"name": "lab-icmp",
				"targets": ["192.0.2.0/30"],
				"ports": [443],
				"modes": ["icmp", "tcp"],
				"banner_grab": {"enabled": false},
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 50, "timeout": "3s"},
				"device_targets": [
					{
						"network": "198.51.100.10",
						"sweep_modes": ["icmp", "tcp"],
						"query_label": "lab-icmp",
						"source": "srql",
						"metadata": {"device_uid": "sr:dev-0001"}
					},
					{
						"network": "198.51.100.20",
						"sweep_modes": ["icmp", "tcp"],
						"query_label": "lab-icmp",
						"source": "srql",
						"metadata": {}
					}
				]
			},
			{
				"id": "sg-2",
				"sweep_group_id": "sg-2",
				"name": "static-only",
				"targets": ["192.0.2.8/30"],
				"ports": [],
				"modes": ["icmp"],
				"banner_grab": {"enabled": false},
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 50, "timeout": "3s"}
			}
		],
		"config_hash": "hash-parity"
	}
}`

const sharedTargetsSweepPayload = `{
	"sweep": {
		"format": "shared-targets/v1",
		"device_table": [
			{"ref": "ip:198.51.100.20", "ip": "198.51.100.20"},
			{"ref": "sr:dev-0001", "ip": "198.51.100.10", "device_uid": "sr:dev-0001"}
		],
		"target_sets": [
			{
				"key": "q-fixturelabquery",
				"target_query": "in:devices tags.env:lab",
				"refs": ["sr:dev-0001", "ip:198.51.100.20"]
			}
		],
		"groups": [
			{
				"id": "sg-1",
				"sweep_group_id": "sg-1",
				"name": "lab-icmp",
				"targets": ["192.0.2.0/30"],
				"ports": [443],
				"modes": ["icmp", "tcp"],
				"banner_grab": {"enabled": false},
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 50, "timeout": "3s"},
				"target_query": "in:devices tags.env:lab",
				"device_target_set": "q-fixturelabquery"
			},
			{
				"id": "sg-2",
				"sweep_group_id": "sg-2",
				"name": "static-only",
				"targets": ["192.0.2.8/30"],
				"ports": [],
				"modes": ["icmp"],
				"banner_grab": {"enabled": false},
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 50, "timeout": "3s"}
			}
		],
		"config_hash": "hash-parity"
	}
}`

func TestParseGatewaySweepConfig_SharedTargetsParity(t *testing.T) {
	log := logger.NewTestLogger()

	legacy, err := parseGatewaySweepConfig([]byte(legacySweepPayload), log)
	if err != nil {
		t.Fatalf("legacy parse failed: %v", err)
	}

	shared, err := parseGatewaySweepConfig([]byte(sharedTargetsSweepPayload), log)
	if err != nil {
		t.Fatalf("shared parse failed: %v", err)
	}

	if !reflect.DeepEqual(legacy, shared) {
		t.Fatalf("shared-targets parse differs from legacy:\nlegacy: %+v\nshared: %+v", legacy, shared)
	}
}

func TestParseGatewaySweepConfig_UnknownFormatErrors(t *testing.T) {
	log := logger.NewTestLogger()

	payload := []byte(`{"sweep": {"format": "yaml", "groups": [], "config_hash": "h"}}`)

	_, err := parseGatewaySweepConfig(payload, log)
	if err == nil {
		t.Fatal("expected error for unknown sweep format, got nil")
	}
	if !strings.Contains(err.Error(), "unsupported sweep config format") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseGatewaySweepConfig_SharedTargetsDanglingRefErrors(t *testing.T) {
	log := logger.NewTestLogger()

	payload := []byte(`{
		"sweep": {
			"format": "shared-targets/v1",
			"device_table": [],
			"target_sets": [{"key": "q-x", "refs": ["sr:missing"]}],
			"groups": [{
				"id": "sg-1", "sweep_group_id": "sg-1", "name": "g",
				"targets": [], "ports": [], "modes": ["icmp"],
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 1, "timeout": "1s"},
				"device_target_set": "q-x"
			}],
			"config_hash": "h"
		}
	}`)

	if _, err := parseGatewaySweepConfig(payload, log); err == nil {
		t.Fatal("expected error for dangling device_table ref, got nil")
	}
}

func TestParseGatewaySweepConfig_SharedTargetsMissingSetErrors(t *testing.T) {
	log := logger.NewTestLogger()

	payload := []byte(`{
		"sweep": {
			"format": "shared-targets/v1",
			"device_table": [],
			"target_sets": [],
			"groups": [{
				"id": "sg-1", "sweep_group_id": "sg-1", "name": "g",
				"targets": [], "ports": [], "modes": ["icmp"],
				"schedule": {"type": "interval", "interval": "15m"},
				"settings": {"concurrency": 1, "timeout": "1s"},
				"device_target_set": "q-missing"
			}],
			"config_hash": "h"
		}
	}`)

	if _, err := parseGatewaySweepConfig(payload, log); err == nil {
		t.Fatal("expected error for missing target set, got nil")
	}
}

type recordingSweepService struct {
	applied *SweepGroupsConfig
	hash    string
}

func (*recordingSweepService) Start(context.Context) error       { return nil }
func (*recordingSweepService) Stop(context.Context) error        { return nil }
func (*recordingSweepService) Name() string                      { return "sweep" }
func (*recordingSweepService) UpdateConfig(*models.Config) error { return nil }

func (*recordingSweepService) GetSweepResults(context.Context, string) (*proto.ResultsResponse, error) {
	return &proto.ResultsResponse{}, nil
}

func (s *recordingSweepService) GetConfigHash() string { return s.hash }

func (s *recordingSweepService) UpdateSweepGroupsContext(_ context.Context, cfg *SweepGroupsConfig) error {
	s.applied = cfg
	s.hash = cfg.ConfigHash
	return nil
}

func TestApplySweepConfig_UnknownFormatKeepsRunningConfig(t *testing.T) {
	svc := &recordingSweepService{}
	loop := &PushLoop{
		server: &Server{services: []Service{svc}},
		logger: logger.NewTestLogger(),
	}
	ctx := context.Background()

	loop.applySweepConfig(ctx, []byte(legacySweepPayload))
	if svc.applied == nil || len(svc.applied.Groups) != 2 {
		t.Fatalf("valid config was not applied: %+v", svc.applied)
	}
	applied := svc.applied

	unknown := []byte(`{"sweep": {"format": "yaml", "groups": [], "config_hash": "h-other"}}`)
	loop.applySweepConfig(ctx, unknown)
	if svc.applied != applied {
		t.Fatalf("unknown-format config replaced the running config: %+v", svc.applied)
	}

	sharedApply := strings.Replace(sharedTargetsSweepPayload, "hash-parity", "hash-shared", 1)
	loop.applySweepConfig(ctx, []byte(sharedApply))
	if svc.applied == applied {
		t.Fatal("shared-targets config was not applied")
	}
	if got := len(svc.applied.Groups[0].DeviceTargets); got != 2 {
		t.Fatalf("shared-targets apply produced %d device targets, want 2", got)
	}
}

func TestAgentCapabilitiesAdvertiseSharedTargets(t *testing.T) {
	caps := agentCapabilities(agentCapabilityOptions{})
	if !slices.Contains(caps, "sweep-config-shared-targets:v1") {
		t.Fatalf("capabilities %v missing sweep-config-shared-targets:v1", caps)
	}
}
