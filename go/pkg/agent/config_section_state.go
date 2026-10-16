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
	"fmt"
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

// Bound on how long a TRANSIENT section failure may defer the config-version commit.
// A transient failure that persists for the same section payload for at least
// transientSectionEscalationAttempts consecutive apply attempts AND at least
// transientSectionEscalationAge is escalated to a permanent failure for that payload:
// the version commits, the ack reports the section as permanent_failure, and the other
// sections stop being held behind it.
//
// Both conditions are required. Attempts alone are reached within a minute by a burst
// of control-stream re-pushes (one per dependency write), which would escalate an
// ordinary blip such as a gateway restart or an add-on that needs a few minutes to pass
// candidate health. Elapsed time alone would escalate an agent that was offline for the
// window after a single attempt. The age matches core's default config_ack_timeout, so a
// section that has deferred for a whole no-ack window is reported by name as a
// permanent section failure rather than as an opaque config_ack_timeout.
const (
	transientSectionEscalationAttempts = 3
	transientSectionEscalationAge      = 30 * time.Minute
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

// addonAssignmentsDeferredError names the add-ons whose assignment could not apply yet,
// so the add-on section's failure (transient, or escalated after the bound) is attributed
// to them in the section status and in the AddonStatus read model.
type addonAssignmentsDeferredError struct {
	addonIDs []string
	err      error
}

func (e *addonAssignmentsDeferredError) Error() string {
	if len(e.addonIDs) == 0 {
		return e.err.Error()
	}

	return fmt.Sprintf("%v: %s", e.err, strings.Join(e.addonIDs, ", "))
}

func (e *addonAssignmentsDeferredError) Unwrap() error { return e.err }

// configSectionFailure is the persistent (in-memory, per process run) failure state for
// one config section, keyed by the section's payload hash so an identical failing payload
// is neither re-attempted nor re-logged every cycle (spec: permanent failures escalate
// once instead of retry-spamming).
type configSectionFailure struct {
	payloadHash string
	version     string // config version at first observation
	reason      string
	disposition addonDeliveryDisposition
	addonIDs    []string  // add-ons the failure is attributable to, when known
	since       time.Time // when this failure state was first observed
	// attempts counts consecutive transient apply attempts of this payload. It is zero
	// for a failure the section itself classified as permanent.
	attempts int
	// escalated marks a transient failure promoted to permanent by the escalation bound.
	// Unlike a classified permanent failure it is re-attempted on every apply, because
	// the condition may still clear on its own.
	escalated bool
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

// applyConfigSection runs one deferrable config section through the failure state
// machine:
//   - if the identical payload already failed permanently, the apply is SKIPPED (no
//     re-attempt, no re-log) and the recorded failure stands until the payload changes;
//   - on success any recorded failure for the section is cleared;
//   - on a permanent failure the state is recorded and escalated ONCE at error level;
//   - a transient failure is recorded with its first-seen time and consecutive attempt
//     count, and stays transient (the caller defers the version commit so the section
//     retries on the next resend) until the escalation bound is reached for the same
//     payload. From then on it is reported as permanent so the version commits.
//
// The add-on assignment section is never skipped (see configSectionReconcilesEveryApply).
func (p *PushLoop) applyConfigSection(
	section, version, payloadHash string,
	apply func() (addonDeliveryDisposition, error),
) addonDeliveryDisposition {
	if !configSectionReconcilesEveryApply(section) && payloadHash != "" &&
		p.configSectionPermanentFailureMatches(section, payloadHash) {
		p.logger.Debug().
			Str("section", section).
			Str("version", version).
			Msg("Skipping config section; identical payload already failed permanently")

		return addonDeliveryPermanentFailure
	}

	disposition, err := apply()
	if errors.Is(err, errAddonActivationHeld) {
		return disposition
	}
	switch disposition {
	case addonDeliverySucceeded:
		p.clearConfigSectionFailure(section)
	case addonDeliveryPermanentFailure:
		p.recordConfigSectionFailure(section, payloadHash, version, err, disposition)
	case addonDeliveryTransientFailure:
		disposition = p.recordTransientConfigSectionFailure(section, payloadHash, version, err, time.Now())
	}

	return disposition
}

// configSectionReconcilesEveryApply reports whether a section must run on every apply
// even when its identical payload already failed permanently. The add-on assignment
// section carries its own per-add-on failure state and backoff and must always reconcile
// systemd/ephemeral desired state.
func configSectionReconcilesEveryApply(section string) bool {
	return section == configSectionAddons
}

// configSectionFailureRetriesOnCommittedVersion reports whether this failure must be
// re-applied on a same-version or NotModified delivery. That is a transient or
// escalated failure once some config version is committed. failure.version is the
// config version at first observation and stays there when the same payload keeps
// failing under a later hash, so it does not select the retry. A classified
// permanent failure is not retried.
func configSectionFailureRetriesOnCommittedVersion(failure configSectionFailure, version string) bool {
	return version != "" &&
		(failure.escalated || failure.disposition == addonDeliveryTransientFailure)
}

// hasRetryableConfigSectionFailure reports whether any transient or escalated
// section failure must be re-applied from the retained response.
func (p *PushLoop) hasRetryableConfigSectionFailure() bool {
	version := p.getConfigVersion()
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	for _, failure := range p.configSectionFailures {
		if configSectionFailureRetriesOnCommittedVersion(failure, version) {
			return true
		}
	}

	return false
}

// configSectionFailureNeedsRetry reports whether this section's transient or
// escalated failure is for payloadHash and must be re-applied. A record for a
// different payload is left untouched.
func (p *PushLoop) configSectionFailureNeedsRetry(section, payloadHash string) bool {
	version := p.getConfigVersion()
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]

	return ok && failure.payloadHash == payloadHash &&
		configSectionFailureRetriesOnCommittedVersion(failure, version)
}

// retainedPayloadMismatch reports whether this section has a failure record for
// some payload other than payloadHash. A retained-body retry must not apply that
// section, because success would clear the other payload's deferral.
func (p *PushLoop) retainedPayloadMismatch(section, payloadHash string) bool {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]

	return ok && failure.payloadHash != payloadHash
}

// configSectionFailureNamesAddon reports whether this section's recorded failure is
// attributed to addonID.
func (p *PushLoop) configSectionFailureNamesAddon(section, addonID string) bool {
	if addonID == "" {
		return false
	}

	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]
	if !ok {
		return false
	}
	for _, id := range failure.addonIDs {
		if id == addonID {
			return true
		}
	}

	return false
}

// activationHeldAddonDecision reports the section disposition an activation-blocked
// add-on contributes and whether this pass may write the section record.
// visibility is the disposition of this apply. A nil recorded failure contributes
// nothing. touchRecord is false when the record must be left as it is.
func activationHeldAddonDecision(
	recorded *configSectionFailure,
	recordedHash, payloadHash string,
	visibility addonDeliveryDisposition,
) (contribution addonDeliveryDisposition, touchRecord bool) {
	if recorded == nil {
		return addonDeliverySucceeded, false
	}
	if recordedHash != payloadHash {
		return addonDeliveryTransientFailure, false
	}
	if recorded.escalated || recorded.disposition == addonDeliveryPermanentFailure {
		return addonDeliveryPermanentFailure, false
	}
	if recorded.disposition == addonDeliveryTransientFailure && visibility != addonDeliveryPermanentFailure {
		return addonDeliveryTransientFailure, false
	}

	return addonDeliverySucceeded, false
}

// configSectionFailureRecord returns a copy of the section's recorded failure.
func (p *PushLoop) configSectionFailureRecord(section string) (*configSectionFailure, string) {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]
	if !ok {
		return nil, ""
	}

	return &failure, failure.payloadHash
}

// recordedVisibilityApplyFailed reports whether the visibility section's last apply
// is still a recorded failure. A same-version add-on retry uses it to keep systemd
// netprobe activation blocked without re-running visibility.
func (p *PushLoop) recordedVisibilityApplyFailed() bool {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	_, ok := p.configSectionFailures[configSectionVisibility]

	return ok
}

// configSectionPermanentFailureMatches reports whether the identical (section, payload)
// permanent failure is already recorded, so the apply can be skipped this cycle. An
// escalated transient failure never matches: it is retried in case it clears.
func (p *PushLoop) configSectionPermanentFailureMatches(section, payloadHash string) bool {
	p.configSectionMu.Lock()
	defer p.configSectionMu.Unlock()

	failure, ok := p.configSectionFailures[section]

	return ok && failure.disposition == addonDeliveryPermanentFailure && !failure.escalated &&
		failure.payloadHash == payloadHash
}

// recordTransientConfigSectionFailure records one transient apply attempt for a section
// and returns the disposition the caller acts on: transient while the escalation bound
// is not reached, permanent once it is. The count re-arms when the payload changes, and
// the record is dropped when the section succeeds (clearConfigSectionFailure).
func (p *PushLoop) recordTransientConfigSectionFailure(
	section, payloadHash, version string,
	err error,
	now time.Time,
) addonDeliveryDisposition {
	p.configSectionMu.Lock()

	failure, ok := p.configSectionFailures[section]
	if !ok || failure.payloadHash != payloadHash || failure.attempts == 0 {
		// First transient observation of this payload: a new payload, or a section
		// whose previous failure was a classified permanent one.
		failure = configSectionFailure{
			payloadHash: payloadHash,
			version:     version,
			disposition: addonDeliveryTransientFailure,
			since:       now,
		}
	}

	failure.attempts++
	failure.reason = configSectionFailureReason(err)
	failure.addonIDs = configSectionFailureAddonIDs(err)

	escalateNow := !failure.escalated &&
		failure.attempts >= transientSectionEscalationAttempts &&
		now.Sub(failure.since) >= transientSectionEscalationAge
	if escalateNow {
		failure.escalated = true
		failure.disposition = addonDeliveryPermanentFailure
	}

	if p.configSectionFailures == nil {
		p.configSectionFailures = make(map[string]configSectionFailure)
	}

	p.configSectionFailures[section] = failure
	p.configSectionMu.Unlock()

	if escalateNow {
		// Logged once per (section, payload); later attempts of the same payload stay
		// escalated without logging again.
		p.logger.Error().
			Err(err).
			Str("section", section).
			Str("version", version).
			Strs("addons", failure.addonIDs).
			Int("attempts", failure.attempts).
			Time("failing_since", failure.since).
			Msg("Config section kept failing transiently; escalating to a permanent failure so the config version commits")
	}

	return failure.disposition
}

func configSectionFailureReason(err error) string {
	if err == nil {
		return ""
	}

	return err.Error()
}

// configSectionFailureAddonIDs returns the add-ons a section failure is attributable to.
func configSectionFailureAddonIDs(err error) []string {
	var attributed *addonConfigApplyError
	if errors.As(err, &attributed) && attributed.addonID != "" {
		return []string{attributed.addonID}
	}

	var deferred *addonAssignmentsDeferredError
	if errors.As(err, &deferred) && len(deferred.addonIDs) > 0 {
		return append([]string(nil), deferred.addonIDs...)
	}

	return nil
}

// recordConfigSectionFailure stores the persistent failure state for a section and
// escalates it once at error level. Re-recording the identical (payload, reason) keeps
// the original observation time and does not log again.
func (p *PushLoop) recordConfigSectionFailure(
	section, payloadHash, version string,
	err error,
	disposition addonDeliveryDisposition,
) {
	reason := configSectionFailureReason(err)
	addonIDs := configSectionFailureAddonIDs(err)

	p.configSectionMu.Lock()

	if existing, ok := p.configSectionFailures[section]; ok &&
		!existing.escalated &&
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
		addonIDs:    addonIDs,
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
		Strs("addons", addonIDs).
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

// configSectionStatuses builds the per-section status list carried on a ConfigAck and on
// the control-stream hello. A version only commits (and acks) once no section is
// transient, so an ack reports success or permanent_failure; the hello reports the
// current state between commits, including transient_failure for a section that is
// deferring the commit.
func (p *PushLoop) configSectionStatuses() []*proto.ConfigSectionStatus {
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

// configSectionStatusesEqual reports whether two status lists carry the same
// section, disposition, error, and since. Attempt counts are not on the wire.
func configSectionStatusesEqual(left, right []*proto.ConfigSectionStatus) bool {
	if len(left) != len(right) {
		return false
	}

	for i := range left {
		if left[i].GetSection() != right[i].GetSection() ||
			left[i].GetDisposition() != right[i].GetDisposition() ||
			left[i].GetError() != right[i].GetError() ||
			left[i].GetSince() != right[i].GetSince() {
			return false
		}
	}

	return true
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

	byAddon := make(map[string]addonConfigFailure)

	for _, failure := range failures {
		if failure.disposition != addonDeliveryPermanentFailure {
			continue
		}
		for _, addonID := range failure.addonIDs {
			byAddon[strings.ToLower(addonID)] = addonConfigFailure{addonID: addonID, reason: failure.reason}
		}
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

// addonConfigFailure is one add-on's share of a permanently failing config section.
type addonConfigFailure struct {
	addonID string
	reason  string
}

func configApplyFailureReason(failure addonConfigFailure) string {
	return "config apply failed: " + failure.reason
}
