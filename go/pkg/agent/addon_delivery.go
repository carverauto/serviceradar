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
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strings"
	"time"

	agentaddon "github.com/carverauto/serviceradar/go/pkg/agent/addon"
	"github.com/carverauto/serviceradar/proto"
)

// errAddonSupervisionUnsupported is recorded as a permanent delivery failure when an
// assignment uses a supervision model this agent build does not implement.
var errAddonSupervisionUnsupported = errors.New("addon supervision model not supported by this agent")

// errAddonDeliveryBackoff is the sentinel returned by deliverAddonArtifact when an
// add-on's prior PERMANENT failure is still inside the backoff window, so the caller
// skips the (addon, version, sha, config)-identical re-download this round.
var errAddonDeliveryBackoff = errors.New("addon artifact delivery in backoff after permanent failure")

// addonDeliveryFailureBackoff is the minimum interval between re-attempting delivery
// of an add-on artifact that previously failed permanently (e.g. a 404 for an object
// that has not been uploaded yet, a sha mismatch, or an invalid signature). Without
// it a permanently-broken assignment is re-downloaded on every config poll (~2s),
// hammering the gateway for a 404 forever. The attempt key includes the artifact's
// (addon_id, version, sha256, config) so a new assignment resets the backoff and is
// retried immediately, and a recovered artifact installs on the next poll past the
// window.
const addonDeliveryFailureBackoff = 5 * time.Minute

// addonDeliveryDisposition classifies how an add-on artifact delivery failure should
// affect the agent's config-version acknowledgement and retry cadence.
type addonDeliveryDisposition int

const (
	// addonDeliverySucceeded: the artifact was staged/verified (or there was nothing
	// to deliver). Does not block the config ack.
	addonDeliverySucceeded addonDeliveryDisposition = iota
	// addonDeliveryPermanentFailure: a failure that retrying soon cannot fix — a 4xx
	// gateway download (notably 404 artifact-not-found), an incomplete artifact
	// reference, a sha256 mismatch, an invalid signature, an unsafe/oversized tarball,
	// or an unsafe path. Recorded as per-add-on failure state, backed off, and MUST NOT
	// block the config-version ack: the assignment is broken upstream, so wedging the
	// whole config apply only freezes every other config section behind it.
	addonDeliveryPermanentFailure
	// addonDeliveryTransientFailure: a failure that may clear on its own — a 5xx gateway
	// response, a connectivity/timeout error, or a missing object store. These MAY defer
	// the config ack so delivery is retried promptly on the next poll.
	addonDeliveryTransientFailure
)

// classifyAddonDeliveryError maps a delivery error returned by stageAndCapability (and
// the staging helpers beneath it) to a disposition. A nil error is a success.
//
// Permanent (do not block the ack; back off):
//   - ErrAddonArtifactIncomplete   — assignment is missing object key / sha256
//   - ErrAddonArtifactHashMismatch — fetched bytes do not match the expected digest
//   - ErrAddonSignatureInvalid     — supplied ed25519 signature failed verification
//   - ErrAddonUnsafePath           — addon_id / version is not a safe path segment
//   - ErrAddonTarballUnsafe / ErrAddonTarballTooLarge / ErrAddonTarballBinaryMissing
//   - ErrAddonArtifactDownloadFailed with a 4xx HTTP status (e.g. 404 not-yet-uploaded)
//
// Transient (may defer the ack; retry promptly):
//   - ErrAddonObjectStoreUnavailable — store not configured / client missing
//   - ErrAddonArtifactDownloadFailed with a 5xx HTTP status (gateway hiccup)
//   - any connectivity / timeout / context error reaching the gateway or object store
func classifyAddonDeliveryError(err error) addonDeliveryDisposition {
	if err == nil {
		return addonDeliverySucceeded
	}

	switch {
	case errors.Is(err, ErrAddonArtifactIncomplete),
		errors.Is(err, ErrAddonArtifactHashMismatch),
		errors.Is(err, ErrAddonSignatureInvalid),
		errors.Is(err, ErrAddonUnsafePath),
		errors.Is(err, ErrAddonTarballUnsafe),
		errors.Is(err, ErrAddonTarballTooLarge),
		errors.Is(err, ErrAddonTarballBinaryMissing),
		errors.Is(err, ErrAddonRuntimeConfigAmbiguous):
		return addonDeliveryPermanentFailure
	case errors.Is(err, ErrAddonObjectStoreUnavailable):
		return addonDeliveryTransientFailure
	}

	// A non-200 gateway download: 4xx is permanent (the object is not there / the
	// reference is rejected), 5xx and anything else is transient.
	if errors.Is(err, ErrAddonArtifactDownloadFailed) {
		if code, ok := gatewayArtifactStatusCode(err); ok {
			if code >= http.StatusBadRequest && code < http.StatusInternalServerError {
				return addonDeliveryPermanentFailure
			}
			return addonDeliveryTransientFailure
		}
		// A download failure with no decoded status (e.g. nil client) is treated as
		// transient — it is an environmental problem, not a broken artifact.
		return addonDeliveryTransientFailure
	}

	// Connectivity, timeout, context cancellation, object-store I/O errors: all transient.
	return addonDeliveryTransientFailure
}

// deliverAddonArtifact stages an add-on artifact with backoff + failure classification
// applied uniformly across every supervision model. It returns the resolved binary path,
// the delivery disposition, and (for transient/permanent failures) the underlying error.
//
//   - If the SAME (addon, version, sha, config) most recently failed permanently and is
//     still in the backoff window, it short-circuits with addonDeliveryPermanentFailure
//     and errAddonDeliveryBackoff WITHOUT re-downloading — the caller leaves current state
//     unchanged and does not block the ack.
//   - On a fresh permanent failure (404, sha mismatch, bad signature, incomplete ref, …)
//     it records the failure (for status + backoff) and returns addonDeliveryPermanentFailure.
//   - On a transient failure it does NOT record/back off (so it retries promptly) and
//     returns addonDeliveryTransientFailure.
//   - On success it clears any recorded failure and returns addonDeliverySucceeded.
func (p *PushLoop) deliverAddonArtifact(
	ctx context.Context,
	a *proto.AddonAssignmentConfig,
	delivery string,
	now time.Time,
) (string, addonDeliveryDisposition, error) {
	if p.addonDeliveryInBackoff(a, now) {
		p.logger.Debug().
			Str("addon", a.GetAddonId()).
			Str("version", a.GetVersion()).
			Dur("backoff", addonDeliveryFailureBackoff).
			Msg("Skipping add-on artifact delivery; still in backoff after a permanent failure")

		return "", addonDeliveryPermanentFailure, errAddonDeliveryBackoff
	}

	binaryPath, err := p.stageAndCapability(ctx, a, delivery)
	if err == nil {
		p.clearAddonDeliveryFailure(a.GetAddonId())
		return binaryPath, addonDeliverySucceeded, nil
	}

	disposition := classifyAddonDeliveryError(err)
	if disposition == addonDeliveryPermanentFailure {
		p.recordAddonDeliveryFailure(a, err, now)
	} else {
		p.recordTransientAddonApplyFailure(a, err, now)
	}

	return "", disposition, err
}

// gatewayArtifactStatusCode extracts the HTTP status code from a gateway download
// failure when one is present in the error chain.
func gatewayArtifactStatusCode(err error) (int, bool) {
	var statusErr *gatewayArtifactStatusError
	if errors.As(err, &statusErr) {
		return statusErr.StatusCode(), true
	}

	return 0, false
}

// addonDeliveryAttemptKey identifies a single (addon, artifact, config) delivery target
// so the backoff only suppresses re-attempts of the SAME broken artifact. Any change to
// the assigned version, artifact sha256, object key, or config resets the key and the
// next reconcile retries immediately — the operator re-pushing or re-building the add-on
// must not be throttled.
func addonDeliveryAttemptKey(a *proto.AddonAssignmentConfig) string {
	return strings.Join([]string{
		strings.TrimSpace(a.GetAddonId()),
		strings.TrimSpace(a.GetVersion()),
		strings.ToLower(strings.TrimSpace(a.GetArtifactSha256())),
		strings.TrimSpace(a.GetArtifactObjectKey()),
		addonAssignmentConfigSHA256(a.GetConfigJson()),
	}, "|")
}

// addonDeliveryFailure records the last permanent delivery failure for an add-on so it
// can be (a) surfaced as per-add-on failure status and (b) backed off.
type addonDeliveryFailure struct {
	key     string    // attempt key the failure is bound to
	at      time.Time // when the permanent failure was last observed
	reason  string    // human-readable cause for status reporting
	version string    // assigned version at failure time (for status reporting)
}

// addonApplyFailure records the latest failed apply/install/delivery attempt for an
// add-on (either permanent or transient) so the status entry for a still-running
// previous version can report the failed candidate version and reason without hiding
// the running state.
type addonApplyFailure struct {
	at          time.Time
	reason      string
	version     string
	disposition string
}

// recordAddonDeliveryFailure stores/refreshes the permanent-failure state for an add-on.
func (p *PushLoop) recordAddonDeliveryFailure(a *proto.AddonAssignmentConfig, err error, now time.Time) {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	if p.addonDeliveryFailures == nil {
		p.addonDeliveryFailures = make(map[string]addonDeliveryFailure)
	}
	if p.addonApplyFailures == nil {
		p.addonApplyFailures = make(map[string]addonApplyFailure)
	}

	id := strings.TrimSpace(a.GetAddonId())
	version := strings.TrimSpace(a.GetVersion())
	reason := err.Error()

	p.addonDeliveryFailures[id] = addonDeliveryFailure{
		key:     addonDeliveryAttemptKey(a),
		at:      now,
		reason:  reason,
		version: version,
	}
	p.addonApplyFailures[id] = addonApplyFailure{
		at:          now,
		reason:      reason,
		version:     version,
		disposition: configSectionDispositionPermanent,
	}
}

// recordTransientAddonApplyFailure stores/refreshes the latest transient apply failure for
// an add-on without entering permanent-delivery backoff.
func (p *PushLoop) recordTransientAddonApplyFailure(
	a *proto.AddonAssignmentConfig,
	err error,
	now time.Time,
) {
	if a == nil || err == nil {
		return
	}

	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	if p.addonApplyFailures == nil {
		p.addonApplyFailures = make(map[string]addonApplyFailure)
	}

	id := strings.TrimSpace(a.GetAddonId())
	if id == "" {
		return
	}

	p.addonApplyFailures[id] = addonApplyFailure{
		at:          now,
		reason:      err.Error(),
		version:     strings.TrimSpace(a.GetVersion()),
		disposition: configSectionDispositionTransient,
	}
}

// addonDeliveryInBackoff reports whether a previously-recorded PERMANENT failure for
// this exact (addon, artifact, config) is still inside the backoff window, so the
// reconcile should skip re-downloading it this round. A different attempt key (new
// version / sha / object key / config) is never in backoff — the assignment changed and
// must be retried immediately.
func (p *PushLoop) addonDeliveryInBackoff(a *proto.AddonAssignmentConfig, now time.Time) bool {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	failure, ok := p.addonDeliveryFailures[strings.TrimSpace(a.GetAddonId())]
	if !ok {
		return false
	}
	if failure.key != addonDeliveryAttemptKey(a) {
		return false
	}

	return now.Sub(failure.at) < addonDeliveryFailureBackoff
}

// clearAddonDeliveryFailure drops any recorded delivery/apply failure for an add-on
// (called once delivery and apply succeed, so a later failure is reported fresh and not
// suppressed).
func (p *PushLoop) clearAddonDeliveryFailure(id string) {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	trimmed := strings.TrimSpace(id)
	delete(p.addonDeliveryFailures, trimmed)
	delete(p.addonApplyFailures, trimmed)
	delete(p.systemdInstallFailures, trimmed)
}

func (p *PushLoop) systemdUpdaterPath() string {
	if p != nil && p.systemdUpdaterPathOverride != "" {
		return p.systemdUpdaterPathOverride
	}

	return AgentUpdaterPath()
}

func statFileIdentity(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "unset"
	}

	info, err := os.Stat(trimmed)
	if err != nil {
		return "missing"
	}

	return fmt.Sprintf("mode=%o:size=%d:mtime=%d", info.Mode(), info.Size(), info.ModTime().UnixNano())
}

// systemdInstallAttemptKey captures every input that can change the outcome of a
// systemd-supervised add-on install, including the on-disk updater executable identity,
// while intentionally excluding ephemeral per-poll fields such as DownloadToken.
func (p *PushLoop) systemdInstallAttemptKey(a *proto.AddonAssignmentConfig, supervision string) string {
	caps := make([]string, 0, len(a.GetOsCapabilities()))
	for _, c := range a.GetOsCapabilities() {
		if trimmed := strings.ToLower(strings.TrimSpace(c)); trimmed != "" {
			caps = append(caps, trimmed)
		}
	}
	sort.Strings(caps)

	resSum := sha256.Sum256(marshalConfigSectionMessage(a.GetResources()))

	return strings.Join([]string{
		strings.TrimSpace(a.GetAddonId()),
		strings.TrimSpace(a.GetVersion()),
		strings.TrimSpace(a.GetArtifactObjectKey()),
		strings.ToLower(strings.TrimSpace(a.GetArtifactSha256())),
		strings.TrimSpace(a.GetArtifactSignature()),
		strings.TrimSpace(a.GetBinaryPath()),
		strings.TrimSpace(supervision),
		addonAssignmentConfigSHA256(a.GetConfigJson()),
		strings.Join(caps, ","),
		hex.EncodeToString(resSum[:]),
		statFileIdentity(p.systemdUpdaterPath()),
	}, "|")
}

// recordSystemdPermanentFailure records a deterministic systemd install/activation refusal
// for both status reporting and input-keyed retry suppression across polls (independent of
// the 5-minute artifact download backoff).
func (p *PushLoop) recordSystemdPermanentFailure(
	a *proto.AddonAssignmentConfig,
	supervision string,
	err error,
	now time.Time,
) {
	if a == nil || err == nil {
		return
	}

	key := p.systemdInstallAttemptKey(a, supervision)

	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	if p.addonDeliveryFailures == nil {
		p.addonDeliveryFailures = make(map[string]addonDeliveryFailure)
	}
	if p.addonApplyFailures == nil {
		p.addonApplyFailures = make(map[string]addonApplyFailure)
	}
	if p.systemdInstallFailures == nil {
		p.systemdInstallFailures = make(map[string]string)
	}

	id := strings.TrimSpace(a.GetAddonId())
	version := strings.TrimSpace(a.GetVersion())
	reason := err.Error()

	p.addonDeliveryFailures[id] = addonDeliveryFailure{
		key:     addonDeliveryAttemptKey(a),
		at:      now,
		reason:  reason,
		version: version,
	}
	p.addonApplyFailures[id] = addonApplyFailure{
		at:          now,
		reason:      reason,
		version:     version,
		disposition: configSectionDispositionPermanent,
	}
	p.systemdInstallFailures[id] = key
}

// systemdInstallSuppressed reports whether an identical systemd install already failed
// permanently with the identical assignment inputs and on-disk updater binary.
func (p *PushLoop) systemdInstallSuppressed(a *proto.AddonAssignmentConfig, supervision string) bool {
	if a == nil {
		return false
	}

	wantKey := p.systemdInstallAttemptKey(a, supervision)

	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	id := strings.TrimSpace(a.GetAddonId())
	recordedKey, ok := p.systemdInstallFailures[id]
	if !ok {
		return false
	}
	if _, hasFailure := p.addonDeliveryFailures[id]; !hasFailure {
		return false
	}

	return recordedKey == wantKey
}

// pruneAddonDeliveryFailures drops failure records for add-ons that are no longer
// assigned, so a removed-then-re-added add-on starts clean.
func (p *PushLoop) pruneAddonDeliveryFailures(keep map[string]bool) {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	for id := range p.addonDeliveryFailures {
		if !keep[id] {
			delete(p.addonDeliveryFailures, id)
		}
	}
	for id := range p.addonApplyFailures {
		if !keep[id] {
			delete(p.addonApplyFailures, id)
		}
	}
	for id := range p.systemdInstallFailures {
		if !keep[id] {
			delete(p.systemdInstallFailures, id)
		}
	}
}

// addonDeliveryFailureSnapshot returns the current per-add-on permanent delivery failures
// so they can be surfaced as add-on failure status alongside the supervised/systemd
// statuses.
func (p *PushLoop) addonDeliveryFailureSnapshot() map[string]addonDeliveryFailure {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	if len(p.addonDeliveryFailures) == 0 {
		return nil
	}

	out := make(map[string]addonDeliveryFailure, len(p.addonDeliveryFailures))
	for id, failure := range p.addonDeliveryFailures {
		out[id] = failure
	}

	return out
}

func (p *PushLoop) addonApplyFailureSnapshot() map[string]addonApplyFailure {
	p.addonDeliveryMu.Lock()
	defer p.addonDeliveryMu.Unlock()

	if len(p.addonApplyFailures) == 0 && len(p.addonDeliveryFailures) == 0 {
		return nil
	}

	out := make(map[string]addonApplyFailure, len(p.addonApplyFailures)+len(p.addonDeliveryFailures))
	for id, failure := range p.addonDeliveryFailures {
		out[id] = addonApplyFailure{
			at:          failure.at,
			reason:      failure.reason,
			version:     failure.version,
			disposition: configSectionDispositionPermanent,
		}
	}
	for id, failure := range p.addonApplyFailures {
		out[id] = failure
	}

	return out
}

// addonDeliveryFailureStatuses synthesizes `addon:<id>` status entries (state=unhealthy,
// last_error=<reason>) for add-ons whose apply/delivery failed when no status entry is
// present in `existing`, and annotates any existing status entry (such as a still-running
// previous version) with the failed candidate's desired_version, apply_error,
// apply_disposition, and apply_observed_at so rollout health gates see candidate install
// failures without losing the running version's state.
func (p *PushLoop) addonDeliveryFailureStatuses(existing []*proto.SidecarStatus) []*proto.SidecarStatus {
	failures := p.addonApplyFailureSnapshot()
	if len(failures) == 0 {
		return nil
	}

	existingByName := make(map[string]*proto.SidecarStatus, len(existing))
	for _, s := range existing {
		if s != nil {
			existingByName[strings.ToLower(s.GetName())] = s
		}
	}

	ids := make([]string, 0, len(failures))
	for id := range failures {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	statuses := make([]agentaddon.Status, 0, len(ids))
	for _, id := range ids {
		failure := failures[id]
		if current, ok := existingByName[strings.ToLower("addon:"+id)]; ok {
			if current.GetVersion() != failure.version || !strings.EqualFold(current.GetState(), string(agentaddon.StateRunning)) {
				current.DesiredVersion = failure.version
				current.ApplyError = failure.reason
				current.ApplyDisposition = failure.disposition
				if !failure.at.IsZero() {
					current.ApplyObservedAt = failure.at.UTC().UnixNano()
				}
			}
			continue
		}
		statuses = append(statuses, agentaddon.Status{
			ID:               id,
			State:            agentaddon.StateUnhealthy,
			Version:          failure.version,
			LastError:        failure.reason,
			DesiredVersion:   failure.version,
			ApplyError:       failure.reason,
			ApplyDisposition: failure.disposition,
			ApplyObservedAt:  failure.at,
		})
	}

	return agentaddon.ToProtoStatuses(statuses)
}
