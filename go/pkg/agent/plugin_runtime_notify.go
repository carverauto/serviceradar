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
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Notification delivery on the agent (tasks 3.2.1 - 3.2.5).
//
// # No new command type, no new execution mode, and no new proto field
//
// A delivery is an ordinary `plugin.run_action` command whose payload carries
// the notificationDeliveryEnvelopeSchema discriminator. Everything the edge
// route needs was already on the wire:
//
//   - the command payload is `CommandRequest.payload_json`
//     (`proto/monitoring.proto`), opaque JSON - notification fields ride there
//     and are not a wire-contract change;
//   - `plugin_assignment_id` / `plugin_package_id` already exist on the
//     run_action payload;
//   - credential grants already ride the action payload as `credential_broker`
//     / `credential_brokers`, and are lifted out host-side by
//     pluginActionCredentialGrants so the material is injected at the HTTP
//     boundary;
//   - trusted-host-only material already has `PluginAssignmentConfig`
//     field 23, `host_params_json`, which is deliberately never merged into
//     `params_json`.
//
// So `proto/monitoring.proto` is unchanged, and no other language binding needs
// regenerating.
//
// # Which guest function runs
//
// The notification envelope carries the exported symbol resolved from the
// package manifest's matching `notifications:` entry. The host uses that
// symbol for this invocation only; the assignment's package-level entrypoint
// remains the default for checks and ordinary actions.

// notificationDeliveryEnvelopeSchema is the discriminator core stamps on a
// plugin.run_action payload that is a notification dispatch. Its Elixir
// counterpart is ServiceRadar.Notifications.Dispatcher.edge_command_schema/0;
// the two strings must stay identical or the gate below stops recognising
// notification traffic and silently degrades to "no gate at all".
//
// Notification delivery deliberately rides the EXISTING plugin.run_action
// command rather than a new command type, so a plugin authored for the edge
// runs unchanged on the platform-resident agent (design D3). The schema field
// is what tells the two apart.
const notificationDeliveryEnvelopeSchema = "serviceradar.notification_delivery.v1"

// notificationDeliveryRequestSchema is the schema under the guest-visible
// notification_delivery host-config key. It is pinned by both notifier SDKs.
const notificationDeliveryRequestSchema = "serviceradar.notification_delivery_request.v1"

// notificationDeliveryConfigKey discriminates notifier host configuration
// from the existing action_invocation ABI.
const notificationDeliveryConfigKey = "notification_delivery"

// notificationDeliveryResultSchema is the schema stamped on the command result
// of a notification dispatch, exactly as the northbound action path stamps
// serviceradar.northbound_action_result.v1 on its own.
//
// The agent does NOT invent the body of that result: whatever the guest
// submitted is passed through, and only the correlation identity
// (delivery_id / channel_id / action_key) and the schema/status defaults are
// stamped on top. Inventing a result shape here would fork the notifier guest
// ABI that the SDKs own (tasks 3.8), so the host stays a courier.
//
// The delivery ROW remains the system of record either way (design D3): this
// result is a wake-up signal, and a lost one is recovered by the reconciler in
// tasks 3.4.5, never by re-deriving state from the command plane.
const notificationDeliveryResultSchema = "serviceradar.notification_delivery_result.v1"

// notificationCredentialInjectionModes is the CLOSED set of credential-broker
// injection modes a notification dispatch may declare. It is the same six names
// the manifest validator allows
// (`ServiceRadar.Plugins.Manifest.@allowed_credential_injection_modes`), and it
// is deliberately narrower than what `applyCredentialBrokerHTTPInjection`
// accepts for legacy integrations - that switch also honours the shorthands
// `header`, `http_basic_auth`, `query_param`, and `http_query`.
//
// Two things follow, and both are the point of the list:
//
//  1. NONE of these six rewrites a URL PATH. A destination whose secret lives in
//     the path - a Slack or Discord incoming webhook - therefore cannot be
//     served by credential injection on the edge route at all. Elixir already
//     refuses those channels on `:edge_agent` at save time
//     (`transports/slack.ex` `route_errors/2`, `transports/discord.ex`) and
//     again at dispatch (`check_route/2`); this is the host-side half, so a
//     dispatch that got past Elixir some other way still cannot smuggle a
//     `url_path` mode past the agent. Adding a URL-path mode is out of scope for
//     v1 and must be added to the HOST first, never to a manifest allowlist
//     first (tasks 3.2.4).
//  2. A plugin author never learns a spelling one surface accepts and another
//     rejects. A manifest carrying `header` fails validation in Elixir; a
//     notification grant carrying `header` fails here.
//
//nolint:gochecknoglobals // closed allowlist, read-only after init
var notificationCredentialInjectionModes = map[string]struct{}{
	"http_header":               {},
	"bearer_token":              {},
	"basic_auth":                {},
	"query":                     {},
	"form_urlencoded":           {},
	"oauth2_password_bearer":    {},
	"oauth2_client_credentials": {},
}

// errPluginNotifyCapabilityDenied is returned when an assignment is asked to
// deliver a notification without holding notify:v1.
//
// This is the enforcement half of the capability. A capability that exists only
// in the Elixir manifest allowlist is UNENFORCED: the control plane can be
// convinced to dispatch to a plugin that never requested the permission, and
// nothing on the execution path objects. `advisory-feed:v1` and
// `producer-schedule:v1` are exactly that defect today; `notify:v1` must not
// become the third.
var errPluginNotifyCapabilityDenied = errors.New(
	"plugin assignment does not hold the notify:v1 capability",
)

var (
	// errNotificationDeliveryInvalid is returned when an envelope carries the
	// notification schema but not the identity a delivery needs. The agent
	// cannot report the outcome of a delivery it cannot name, so a nameless
	// delivery is refused rather than run.
	errNotificationDeliveryInvalid = errors.New("notification delivery envelope is not well formed")

	// errNotificationTargetMissing is returned when a notification envelope
	// addresses neither a plugin assignment nor a plugin package. See
	// resolveNotificationAssignmentID for why the agent will not guess.
	errNotificationTargetMissing = errors.New(
		"notification delivery names neither plugin_assignment_id nor plugin_package_id",
	)

	// errNotificationTargetAmbiguous is returned when a notification envelope
	// addresses a package that this agent runs more than one assignment of.
	// Picking one would silently deliver an alert with another channel's
	// configuration, so it fails closed.
	errNotificationTargetAmbiguous = errors.New(
		"notification delivery package resolves to more than one plugin assignment",
	)

	// errNotificationCredentialInjectionUnsupported is returned when a
	// notification dispatch declares a credential-broker injection mode outside
	// notificationCredentialInjectionModes.
	errNotificationCredentialInjectionUnsupported = errors.New(
		"notification credential grant declares an injection mode the host will not serve",
	)
)

// notificationDeliveryEnvelope is the identity and addressing half of the
// delivery request. The rendered payload itself is not decoded here:
// buildNotificationPluginConfig carries it under the notifier SDK's typed
// `notification_delivery` config key, so the host never has to understand a
// notification body to deliver one.
//
// It is deliberately NOT a strict decode of the whole payload: an unknown field
// added by a newer control plane must not make an older agent fail to RECOGNISE
// a notification, because failing to recognise one means failing to gate it.
//
// Its Elixir counterpart is the payload map built by
// `ServiceRadar.Notifications.Dispatcher.edge_dispatch/4`.
type notificationDeliveryEnvelope struct {
	Schema        string `json:"schema"`
	ActionKey     string `json:"action_key"`
	ProviderKey   string `json:"provider_key"`
	ChannelID     string `json:"channel_id"`
	DeliveryID    string `json:"delivery_id"`
	PayloadFormat string `json:"payload_format"`
	DedupeKey     string `json:"dedupe_key"`
	Entrypoint    string `json:"entrypoint"`
	IsTest        bool   `json:"is_test"`

	// PluginPackageID is the addressing a notification can always carry: a
	// channel binds to a NotificationProvider, and a `:wasm_plugin` provider
	// carries `plugin_package_id` + `action_key`. A plugin assignment id is not
	// on the channel at all (`notification_channel.ex`), so core derives one
	// (`ServiceRadar.Notifications.PluginTarget`) and sends it alongside as the
	// command payload's `plugin_assignment_id`. See
	// resolveNotificationAssignmentID for which wins.
	PluginPackageID string `json:"plugin_package_id"`
}

// decodeNotificationDelivery reports whether an action invocation payload is a
// notification dispatch, and returns the envelope it carries.
//
// A payload that is not valid JSON, or is JSON but not an object, is not a
// notification: it cannot carry the schema discriminator. Those cases fall
// through to the ordinary action path, which rejects them on its own terms.
//
// Recognition is deliberately in TWO stages, and the split is a security
// control rather than tidiness. Failing to recognise a notification means
// failing to GATE it, so nothing about a payload other than the discriminator
// itself may decide the question. A single strict decode would let a payload
// that claims this schema but carries, say, a numeric `is_test` fall through to
// the ungated northbound path and run a notifier with no notify:v1 at all.
//
// So: stage one proves the payload is a JSON object naming this schema; stage
// two reads the identity fields and TOLERATES a wrong type on any of them. A
// field that will not decode stays zero, and validate() refuses the delivery on
// the grounds it can no longer be correlated - which is a refusal, not a
// bypass.
func decodeNotificationDelivery(
	invocationPayload json.RawMessage,
) (notificationDeliveryEnvelope, bool) {
	if len(bytes.TrimSpace(invocationPayload)) == 0 {
		return notificationDeliveryEnvelope{}, false
	}

	var fields map[string]json.RawMessage
	if err := json.Unmarshal(invocationPayload, &fields); err != nil {
		return notificationDeliveryEnvelope{}, false
	}

	rawSchema, ok := fields["schema"]
	if !ok {
		return notificationDeliveryEnvelope{}, false
	}

	var schema string
	if err := json.Unmarshal(rawSchema, &schema); err != nil {
		return notificationDeliveryEnvelope{}, false
	}
	if strings.TrimSpace(schema) != notificationDeliveryEnvelopeSchema {
		return notificationDeliveryEnvelope{}, false
	}

	// The error is deliberately discarded: a type error on a non-discriminator
	// field must not hide the envelope, and encoding/json still fills every
	// field that did decode.
	var envelope notificationDeliveryEnvelope
	_ = json.Unmarshal(invocationPayload, &envelope)

	envelope.Schema = notificationDeliveryEnvelopeSchema
	envelope.ActionKey = strings.TrimSpace(envelope.ActionKey)
	envelope.ProviderKey = strings.TrimSpace(envelope.ProviderKey)
	envelope.ChannelID = strings.TrimSpace(envelope.ChannelID)
	envelope.DeliveryID = strings.TrimSpace(envelope.DeliveryID)
	envelope.PayloadFormat = strings.TrimSpace(envelope.PayloadFormat)
	envelope.DedupeKey = strings.TrimSpace(envelope.DedupeKey)
	envelope.Entrypoint = strings.TrimSpace(envelope.Entrypoint)
	envelope.PluginPackageID = strings.TrimSpace(envelope.PluginPackageID)

	return envelope, true
}

// notificationActionEntrypoint returns the notifier export named by core for
// this invocation. It never mutates or copies the registered assignment, whose
// mutexes protect runtime state that can be refreshed while an action runs.
func notificationActionEntrypoint(
	assignment *pluginAssignment,
	invocationPayload json.RawMessage,
) string {
	if assignment == nil {
		return ""
	}

	envelope, isNotification := decodeNotificationDelivery(invocationPayload)
	if !isNotification || envelope.Entrypoint == "" {
		return assignment.Entrypoint
	}

	return envelope.Entrypoint
}

// pluginActionNotificationEnvelope reports whether an action invocation payload
// is a notification dispatch, and returns the notifier key it addresses. It is
// the capability gate's view of decodeNotificationDelivery: the gate needs only
// the notifier name, for the denial log line.
func pluginActionNotificationEnvelope(invocationPayload json.RawMessage) (string, bool) {
	envelope, ok := decodeNotificationDelivery(invocationPayload)
	return envelope.ActionKey, ok
}

// validate rejects an envelope that carries the notification schema without the
// identity a delivery needs.
//
// `delivery_id` and `channel_id` are what let core correlate the command result
// back to the row that is the system of record; `action_key` is what names the
// notifier inside the package. A dispatch missing any of the three cannot be
// reported on, and a delivery nobody can report on is worse than one that never
// ran - it looks sent.
func (e notificationDeliveryEnvelope) validate() error {
	missing := make([]string, 0, 3)
	if e.DeliveryID == "" {
		missing = append(missing, "delivery_id")
	}
	if e.ChannelID == "" {
		missing = append(missing, "channel_id")
	}
	if e.ActionKey == "" {
		missing = append(missing, "action_key")
	}

	if len(missing) > 0 {
		return fmt.Errorf("%w: missing %s", errNotificationDeliveryInvalid, strings.Join(missing, ", "))
	}

	return nil
}

// deliversNotifications reports whether the assignment's NARROWED capability
// set carries notify:v1.
//
// Narrowed is the operative word: what reaches the agent is
// effective_capabilities, computed from package approval and then the
// assignment override (edge/agent_config_generator.ex). An operator who denies
// notify:v1 at either step lands here as a missing key, which is why the gate
// reads the assignment rather than the package manifest.
func (a *pluginAssignment) deliversNotifications() bool {
	return a != nil && a.Capabilities != nil && a.Capabilities[pluginCapabilityNotify]
}

// authorizeNotificationDelivery is the gate. It runs before the module is
// loaded, so a denied plugin is never instantiated and no part of the delivery
// request - which carries alert content - reaches guest memory.
//
// Two security controls, both fail-closed by construction:
//
//  1. notify:v1 must be present in the assignment's NARROWED capability set.
//     A nil assignment, a nil capability map, and an unknown assignment all
//     deny.
//  2. every credential-broker grant riding on the delivery must declare an
//     injection mode from the closed canonical set. This is checked here, at
//     admission, rather than only at the HTTP boundary deep inside the run, so
//     an unserviceable grant costs no module instantiation and produces one
//     legible error instead of a generic denied request the guest has to
//     interpret.
//
// It is called from BOTH entrances to plugin execution (RunAction and
// runPluginVerb). A permission with one guarded entrance is not enforced.
func (m *PluginManager) authorizeNotificationDelivery(
	assignment *pluginAssignment,
	invocationPayload json.RawMessage,
) error {
	envelope, isNotification := decodeNotificationDelivery(invocationPayload)
	if !isNotification {
		return nil
	}

	if !assignment.deliversNotifications() {
		m.logNotificationDenied(assignment, envelope, pluginCapabilityNotify,
			"Denied notification delivery for plugin assignment without notify:v1")

		return errPluginNotifyCapabilityDenied
	}

	if err := notificationCredentialGrantsServiceable(invocationPayload); err != nil {
		m.logNotificationDenied(assignment, envelope, "credential_injection",
			"Denied notification delivery declaring an unsupported credential injection mode")

		return err
	}

	return nil
}

// notificationCredentialGrantsServiceable rejects a delivery whose credential
// grants ask for an injection mode outside notificationCredentialInjectionModes.
//
// A grant with no `inject.type` asks for nothing and is left alone: that is how
// a notifier that authenticates from its own configuration (no host injection)
// looks, and refusing it would break the common case to guard the rare one.
func notificationCredentialGrantsServiceable(invocationPayload json.RawMessage) error {
	grants, err := pluginActionCredentialGrants(invocationPayload)
	if err != nil {
		// Undecodable grants are not "no grants". Fail closed: the alternative
		// is treating a malformed grant block as an absent one, which is how a
		// credential requirement silently stops being enforced.
		return fmt.Errorf("%w: %w", errNotificationDeliveryInvalid, err)
	}

	for i := range grants {
		mode := strings.ToLower(strings.TrimSpace(grants[i].Inject["type"]))
		if mode == "" {
			continue
		}
		if _, ok := notificationCredentialInjectionModes[mode]; !ok {
			return fmt.Errorf("%w: %q", errNotificationCredentialInjectionUnsupported, mode)
		}
	}

	return nil
}

func (m *PluginManager) logNotificationDenied(
	assignment *pluginAssignment,
	envelope notificationDeliveryEnvelope,
	control string,
	message string,
) {
	if m == nil || m.logger == nil {
		return
	}

	event := m.logger.Warn().Str("control", control)
	if assignment != nil {
		event = event.
			Str("assignment_id", assignment.AssignmentID).
			Str("plugin_id", assignment.PluginID)
	}
	if envelope.ActionKey != "" {
		event = event.Str("action_key", envelope.ActionKey)
	}
	if envelope.DeliveryID != "" {
		event = event.Str("delivery_id", envelope.DeliveryID)
	}

	event.Msg(message)
}

// resolveNotificationAssignmentID picks the plugin assignment a notification
// delivery addresses, and refuses to guess.
//
// Precedence:
//
//  1. an explicit `plugin_assignment_id` on the command payload. This is the
//     exact address and always wins. `ServiceRadar.Notifications.PluginTarget`
//     derives it in core, where package approval and `effective_capabilities`
//     can also be checked before the command is sent - which the agent cannot
//     do, because it only ever sees what already survived narrowing.
//  2. `plugin_package_id` from the envelope, resolved against this agent's
//     assignments. This is the addressing the notification data model itself
//     carries: a NotificationChannel binds to a provider, and a `:wasm_plugin`
//     provider carries `plugin_package_id` + `action_key`. It is what keeps the
//     host able to place a delivery on its own terms rather than depending on
//     core's view of agent-local assignment ids being current.
//
// Ambiguity is an error, never a choice. Two assignments of one package on one
// agent are two different channel configurations - two different PagerDuty
// routing keys, two different destinations - so picking either one would
// deliver the alert to the wrong place and record it as sent. The failure is
// legible and retryable; the wrong destination is neither.
func (m *PluginManager) resolveNotificationAssignmentID(
	explicitAssignmentID string,
	envelope notificationDeliveryEnvelope,
) (string, error) {
	if assignmentID := strings.TrimSpace(explicitAssignmentID); assignmentID != "" {
		return assignmentID, nil
	}

	packageID := envelope.PluginPackageID
	if packageID == "" {
		return "", errNotificationTargetMissing
	}

	matches := m.assignmentIDsForPackage(packageID)
	switch len(matches) {
	case 0:
		return "", fmt.Errorf("%w for plugin package %q", errPluginAssignmentNotFound, packageID)
	case 1:
		return matches[0], nil
	default:
		return "", fmt.Errorf("%w: package %q has %d assignments (%s)",
			errNotificationTargetAmbiguous, packageID, len(matches), strings.Join(matches, ", "))
	}
}

// assignmentIDsForPackage returns every assignment this agent runs for a plugin
// package, sorted so the ambiguity error names the same set every time.
func (m *PluginManager) assignmentIDsForPackage(packageID string) []string {
	if m == nil {
		return nil
	}

	packageID = strings.TrimSpace(packageID)
	if packageID == "" {
		return nil
	}

	m.mu.RLock()
	defer m.mu.RUnlock()

	matches := make([]string, 0, 1)
	for _, runner := range m.runners {
		if runner == nil || runner.assignment == nil {
			continue
		}
		if runner.assignment.PackageID == packageID {
			matches = append(matches, runner.assignment.AssignmentID)
		}
	}
	for _, assignment := range m.actions {
		if assignment != nil && assignment.PackageID == packageID {
			matches = append(matches, assignment.AssignmentID)
		}
	}

	sort.Strings(matches)

	return matches
}
