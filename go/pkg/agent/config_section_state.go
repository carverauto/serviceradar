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

package agent

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/proto"
	gproto "google.golang.org/protobuf/proto"
)

// Config section identifiers reported in the per-section config ack. These are the
// sections with failure-disposition semantics (they can defer or permanently fail a
// config apply). Purely idempotent sections (sweep, mapper, sysmon, SNMP, checks) log
// their own failures, never wedge the version, and are not tracked here.
const (
	configSectionBumblebee         = "bumblebee"
	configSectionEndpointInventory = "endpoint_inventory"
	configSectionAddons            = "addons"
	configSectionVisibility        = "visibility"
)

// ackedConfigSections fixes the order sections appear in a ConfigAck.
func ackedConfigSections() [4]string {
	return [...]string{
		configSectionBumblebee,
		configSectionEndpointInventory,
		configSectionAddons,
		configSectionVisibility,
	}
}

// Wire values for ConfigSectionStatus.disposition. Core treats an ack without section
// statuses as a legacy whole-version ack, so these only ever ride on new agents.
const (
	configSectionDispositionSuccess   = "success"
	configSectionDispositionTransient = "transient_failure"
	configSectionDispositionPermanent = "permanent_failure"
)

// addonConfigApplyError attributes a config-section apply failure to a specific add-on
// (e.g. the netprobe add-on config merged during the visibility section), so the failure
// can be surfaced as an unhealthy `addon:<id>` status entry in the fleet view.
type addonConfigApplyError struct {
	addonID string
	err     error
}

func (e *addonConfigApplyError) Error() string { return e.err.Error() }
func (e *addonConfigApplyError) Unwrap() error { return e.err }

// configSectionFailure is the persistent (in-memory, per process run) failure state for
// one config section, keyed by the section's payload hash so an identical failing payload
// is neither re-attempted nor re-logged every cycle (spec: permanent failures escalate
// once instead of retry-spamming).
type configSectionFailure struct {
	payloadHash string
	version     string // config version at first observation
	reason      string
	disposition addonDeliveryDisposition
	addonID     string    // non-empty when the failure is attributable to one add-on
	since       time.Time // when this failure state was first observed
}

// hashConfigSectionPayload derives a stable identity for a section's input payload. The
// parts are the deterministic proto encodings and raw JSON the section consumes; a hash
// change means the payload changed and a permanently-failed section must be re-evaluated.
func hashConfigSectionPayload(parts ...[]byte) string {
	h := sha256.New()

	for _, part := range parts {
		_, _ = h.Write(part)
		// Separator so ("ab","c") and ("a","bc") hash differently.
		_, _ = h.Write([]byte{0})
	}

	return hex.EncodeToString(h.Sum(nil))
}

// marshalConfigSectionMessage renders a proto message deterministically for payload
// hashing; a nil message hashes as empty.
func marshalConfigSectionMessage(m gproto.Message) []byte {
	out, err := gproto.MarshalOptions{Deterministic: true}.Marshal(m)
	if err != nil {
		return nil
	}

	return out
}

// marshalAddonAssignmentsForHash renders each add-on assignment deterministically so the
// visibility section (which merges the netprobe assignment's config_json) re-evaluates
// when any assignment changes.
func marshalAddonAssignmentsForHash(addons []*proto.AddonAssignmentConfig) [][]byte {
	parts := make([][]byte, 0, len(addons))
	for _, a := range addons {
		parts = append(parts, marshalConfigSectionMessage(a))
	}

	return parts
}

// applyConfigSection runs one deferrable config section through the permanent-failure
// state machine:
//   - if the identical payload already failed permanently, the apply is SKIPPED (no
//     re-attempt, no re-log) and the recorded failure stands until the payload changes;
//   - on success any recorded failure for the section is cleared;
//   - on a permanent failure the state is recorded and escalated ONCE at error level;
//   - a transient failure is neither skipped nor recorded — the caller defers the
//     version commit so the gateway resends and the section retries next cycle.
//
// An empty payloadHash disables the skip (used for the add-on assignment section, which
// has its own per-add-on backoff and must always reconcile systemd/ephemeral state).
func (p *PushLoop) applyConfigSection(
	section, version, payloadHash string,
	apply func() (addonDeliveryDisposition, error),
) addonDeliveryDisposition {
	if payloadHash != "" && p.configSectionPermanentFailureMatches(section, payloadHash) {
		p.logger.Debug().
			Str("section", section).
			Str("version", version).
			Msg("Skipping config section; identical payload already failed permanently")

		return addonDeliveryPermanentFailure
	}

	disposition, err := apply()
	switch disposition {
	case addonDeliverySucceeded:
		p.clearConfigSectionFailure(section)
	case addonDeliveryPermanentFailure:
		p.recordConfigSectionFailure(section, payloadHash, version, err, disposition)
	case addonDeliveryTransientFailure:
		// Deliberately not recorded: the caller warns + defers, and the section retries
		// on the next resend of the (still uncommitted) version.
	}

	return disposition
}

// configSectionPermanentFailureMatches reports whether the identical (section, payload)
// permanent failure is already recorded, so the apply can be skipped this cycle.
func (p *PushLoop) configSectionPermanentFailureMatches(section, payloadHash string) bool {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]

	return ok && failure.disposition == addonDeliveryPermanentFailure && failure.payloadHash == payloadHash
}

// recordConfigSectionFailure stores the persistent failure state for a section and
// escalates it once at error level. Re-recording the identical (payload, reason) keeps
// the original observation time and does not log again.
func (p *PushLoop) recordConfigSectionFailure(
	section, payloadHash, version string,
	err error,
	disposition addonDeliveryDisposition,
) {
	reason := ""
	if err != nil {
		reason = err.Error()
	}

	addonID := ""

	var attributed *addonConfigApplyError
	if errors.As(err, &attributed) {
		addonID = attributed.addonID
	}

	p.configSectionMu.Lock()

	if existing, ok := p.configSectionFailures[section]; ok &&
		existing.payloadHash == payloadHash &&
		existing.disposition == disposition &&
		existing.reason == reason {
		// Identical failure state: keep the original since-timestamp, no re-escalation.
		p.configSectionMu.Unlock()
		return
	}

	if p.configSectionFailures == nil {
		p.configSectionFailures = make(map[string]configSectionFailure)
	}

	p.configSectionFailures[section] = configSectionFailure{
		payloadHash: payloadHash,
		version:     version,
		reason:      reason,
		disposition: disposition,
		addonID:     addonID,
		since:       time.Now(),
	}
	p.configSectionMu.Unlock()

	// Escalate ONCE per (section, payload) at error level. The version commits and the
	// ack carries the failed section status, so this is the only log line the failure
	// produces until its payload changes (replaces the old per-cycle info/warn spam).
	p.logger.Error().
		Err(err).
		Str("section", section).
		Str("version", version).
		Str("addon", addonID).
		Bool("permanent", disposition == addonDeliveryPermanentFailure).
		Msg("Config section failed permanently; will not re-attempt until its payload changes")
}

// clearConfigSectionFailure drops the recorded failure for a section once it applies
// successfully, so a later failure is reported fresh.
func (p *PushLoop) clearConfigSectionFailure(section string) {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	delete(p.configSectionFailures, section)
}

// configSectionFailureSnapshot returns a copy of the current per-section failure state.
func (p *PushLoop) configSectionFailureSnapshot() map[string]configSectionFailure {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	if len(p.configSectionFailures) == 0 {
		return nil
	}

	out := make(map[string]configSectionFailure, len(p.configSectionFailures))
	for section, failure := range p.configSectionFailures {
		out[section] = failure
	}

	return out
}

// configSectionAckStatuses builds the per-section status list carried on a ConfigAck.
// Acks are only sent once a version commits, so at ack time every tracked section is
// either healthy or in a recorded permanent-failure state.
func (p *PushLoop) configSectionAckStatuses() []*proto.ConfigSectionStatus {
	failures := p.configSectionFailureSnapshot()
	sections := ackedConfigSections()

	statuses := make([]*proto.ConfigSectionStatus, 0, len(sections))
	for _, section := range sections {
		status := &proto.ConfigSectionStatus{
			Section:     section,
			Disposition: configSectionDispositionSuccess,
		}

		if failure, ok := failures[section]; ok {
			status.Disposition = configSectionDispositionString(failure.disposition)
			status.Error = failure.reason
			status.Since = failure.since.Unix()
		}

		statuses = append(statuses, status)
	}

	return statuses
}

// configSectionDispositionString maps a disposition to its ConfigSectionStatus wire value.
func configSectionDispositionString(d addonDeliveryDisposition) string {
	switch d {
	case addonDeliveryPermanentFailure:
		return configSectionDispositionPermanent
	case addonDeliveryTransientFailure:
		return configSectionDispositionTransient
	case addonDeliverySucceeded:
		return configSectionDispositionSuccess
	}

	return configSectionDispositionSuccess
}

// configApplyFailureStatuses surfaces permanently-failing add-on config sections in the
// AddonStatus read model (parity with addonDeliveryFailureStatuses for artifact
// failures). Unlike delivery failures — where a still-running last-known-good process is
// the richer truth — a config-apply failure means the add-on is RUNNING WITH THE WRONG
// CONFIG (the netprobe bootstrap-only incident), so an existing `addon:<id>` entry is
// overridden to unhealthy in place; add-ons without an entry get one synthesized. The
// returned slice contains only the synthesized additions.
func (p *PushLoop) configApplyFailureStatuses(existing []*proto.SidecarStatus) []*proto.SidecarStatus {
	failures := p.configSectionFailureSnapshot()
	if len(failures) == 0 {
		return nil
	}

	byAddon := make(map[string]configSectionFailure)

	for _, failure := range failures {
		if failure.disposition != addonDeliveryPermanentFailure || failure.addonID == "" {
			continue
		}
		byAddon[strings.ToLower(failure.addonID)] = failure
	}

	if len(byAddon) == 0 {
		return nil
	}

	handled := make(map[string]bool, len(byAddon))

	for _, status := range existing {
		if status == nil {
			continue
		}

		id, ok := strings.CutPrefix(strings.ToLower(status.GetName()), "addon:")
		if !ok {
			continue
		}

		failure, ok := byAddon[id]
		if !ok {
			continue
		}

		status.State = string(agentaddon.StateUnhealthy)
		status.LastError = configApplyFailureReason(failure)
		handled[id] = true
	}

	ids := make([]string, 0, len(byAddon))

	for id := range byAddon {
		if !handled[id] {
			ids = append(ids, id)
		}
	}

	sort.Strings(ids)

	statuses := make([]agentaddon.Status, 0, len(ids))
	for _, id := range ids {
		failure := byAddon[id]
		statuses = append(statuses, agentaddon.Status{
			ID:        failure.addonID,
			State:     agentaddon.StateUnhealthy,
			LastError: configApplyFailureReason(failure),
		})
	}

	return agentaddon.ToProtoStatuses(statuses)
}

func configApplyFailureReason(failure configSectionFailure) string {
	return "config apply failed: " + failure.reason
}
