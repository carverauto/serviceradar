/*
 * Copyright 2026 Carver Automation Corporation.
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

package snmp

import (
	"errors"
	"testing"
)

// Hosts are literal IPs throughout: validateHostAddress falls back to a DNS
// lookup for anything that does not parse as an IP, and a unit test must not
// depend on the resolver.
func agentTarget(name, host string) Target {
	return Target{
		Name: name,
		Host: host,
		Port: 161,
		OIDs: []OIDConfig{{OID: ".1.3.6.1.2.1.1.3.0", Name: "uptime", DataType: TypeGauge}},
	}
}

// The regression this exists for: agent config is pushed from the control plane
// and covers a whole fleet, so one unusable device must not take the rest of
// the fleet's polling down with it.
func TestValidateForAgentDropsOneBadTargetAndKeepsTheRest(t *testing.T) {
	t.Parallel()

	config := &SNMPConfig{
		Enabled: true,
		Targets: []Target{
			agentTarget("edge-wlc-01", "10.0.0.1"),
			// A device named by FQDN. Dots are not valid target-name
			// characters, and the control plane does not sanitize
			// device.name/hostname before compiling it into a target.
			agentTarget("clearpass.example.test", "10.0.0.2"),
			agentTarget("edge-wlc-02", "10.0.0.3"),
		},
	}

	rejections, err := config.ValidateForAgent()
	if err != nil {
		t.Fatalf("ValidateForAgent returned error: %v", err)
	}

	if len(config.Targets) != 2 {
		t.Fatalf("kept %d targets, want 2", len(config.Targets))
	}

	for _, target := range config.Targets {
		if target.Name == "clearpass.example.test" {
			t.Fatal("invalid target survived validation")
		}
	}

	if len(rejections) != 1 {
		t.Fatalf("got %d rejections, want 1", len(rejections))
	}

	if rejections[0].Name != "clearpass.example.test" || rejections[0].Host != "10.0.0.2" {
		t.Fatalf("rejection does not identify the dropped target: %+v", rejections[0])
	}

	if !errors.Is(rejections[0].Err, errInvalidTargetName) {
		t.Fatalf("rejection reason = %v, want errInvalidTargetName", rejections[0].Err)
	}
}

// A duplicate name must cost only the duplicate. The first target claiming a
// name keeps it.
func TestValidateForAgentDropsOnlyTheDuplicate(t *testing.T) {
	t.Parallel()

	config := &SNMPConfig{
		Enabled: true,
		Targets: []Target{
			agentTarget("shared-name", "10.0.0.1"),
			agentTarget("shared-name", "10.0.0.2"),
		},
	}

	rejections, err := config.ValidateForAgent()
	if err != nil {
		t.Fatalf("ValidateForAgent returned error: %v", err)
	}

	if len(config.Targets) != 1 || config.Targets[0].Host != "10.0.0.1" {
		t.Fatalf("expected the first claimant to survive, got %+v", config.Targets)
	}

	if len(rejections) != 1 || !errors.Is(rejections[0].Err, errDuplicateTargetName) {
		t.Fatalf("expected one duplicate-name rejection, got %+v", rejections)
	}
}

// Dropping is for partial failure. A config with nothing left to poll is a
// configuration failure and must still be reported as one, with the reasons
// attached so the caller can say why.
func TestValidateForAgentErrorsWhenEveryTargetIsDropped(t *testing.T) {
	t.Parallel()

	config := &SNMPConfig{
		Enabled: true,
		Targets: []Target{
			agentTarget("bad.name.one", "10.0.0.1"),
			agentTarget("bad.name.two", "10.0.0.2"),
		},
	}

	rejections, err := config.ValidateForAgent()
	if !errors.Is(err, errNoTargets) {
		t.Fatalf("err = %v, want errNoTargets", err)
	}

	if len(rejections) != 2 {
		t.Fatalf("got %d rejections, want 2 so the caller can log both", len(rejections))
	}
}

func TestValidateForAgentAcceptsDisabledAndRejectsEmpty(t *testing.T) {
	t.Parallel()

	disabled := &SNMPConfig{Enabled: false}
	if rejections, err := disabled.ValidateForAgent(); err != nil || rejections != nil {
		t.Fatalf("disabled config: rejections=%v err=%v", rejections, err)
	}

	empty := &SNMPConfig{Enabled: true}
	if _, err := empty.ValidateForAgent(); !errors.Is(err, errNoTargets) {
		t.Fatalf("empty config err = %v, want errNoTargets", err)
	}
}

// A target that survives must still be fully defaulted. Dropping siblings must
// not skip the defaulting the old loop did on the way through.
func TestValidateForAgentStillDefaultsSurvivingTargets(t *testing.T) {
	t.Parallel()

	config := &SNMPConfig{
		Enabled: true,
		Targets: []Target{
			agentTarget("bad.name", "10.0.0.1"),
			{
				Name: "good-target",
				Host: "10.0.0.2",
				OIDs: []OIDConfig{{OID: ".1.3.6.1.2.1.1.3.0", Name: "uptime", DataType: TypeGauge}},
			},
		},
	}

	if _, err := config.ValidateForAgent(); err != nil {
		t.Fatalf("ValidateForAgent returned error: %v", err)
	}

	if len(config.Targets) != 1 {
		t.Fatalf("kept %d targets, want 1", len(config.Targets))
	}

	survivor := config.Targets[0]
	if survivor.Port != defaultPort {
		t.Errorf("Port = %d, want default %d", survivor.Port, defaultPort)
	}

	if survivor.Retries != defaultRetries {
		t.Errorf("Retries = %d, want default %d", survivor.Retries, defaultRetries)
	}

	if survivor.MaxPoints != defaultMaxPoints {
		t.Errorf("MaxPoints = %d, want default %d", survivor.MaxPoints, defaultMaxPoints)
	}
}
