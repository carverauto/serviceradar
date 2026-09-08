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
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	notifyAssignmentID = "notify-assignment-1"
	notifyPluginID     = "acme-notifier"
	notifyPackageID    = "acme-notifier-package"
	notifyActionKey    = "pagerduty"
	notifyChannelID    = "018f2fd1-f0ff-7cf0-9dc0-000000000010"
	notifyDeliveryID   = "018f2fd1-f0ff-7cf0-9dc0-000000000011"
)

// notificationDeliveryPayload is the shape core's Dispatcher.edge_dispatch/4
// puts on the wire. Only `schema` is load bearing for the gate; the rest is
// present so the fixture stays recognisable to a reader diffing it against
// `dispatcher.ex`.
func notificationDeliveryPayload(t *testing.T) json.RawMessage {
	t.Helper()

	return notificationDeliveryPayloadWith(t, nil)
}

// notificationDeliveryPayloadWith builds the same envelope with extra or
// overridden fields, so a test can add addressing or credential grants without
// restating the contract.
func notificationDeliveryPayloadWith(t *testing.T, extra map[string]any) json.RawMessage {
	t.Helper()

	envelope := map[string]any{
		"schema":            notificationDeliveryEnvelopeSchema,
		"action_key":        notifyActionKey,
		"entrypoint":        "notify_pagerduty",
		"provider_key":      "acme-pagerduty",
		"channel_id":        notifyChannelID,
		"delivery_id":       notifyDeliveryID,
		"plugin_package_id": notifyPackageID,
		"intent":            "send",
		"payload_format":    "json",
		"rendered_payload":  map[string]any{"title": "disk full"},
		"channel_config": map[string]any{
			"api_token_secret_ref": "credentialref:notification-secret:channel-1",
		},
		"dedupe_key": "rule-42|device_id=abc",
		"is_test":    false,
	}
	for key, value := range extra {
		if value == nil {
			delete(envelope, key)
			continue
		}
		envelope[key] = value
	}

	payload, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal notification payload: %v", err)
	}

	return payload
}

// newNotifyTestManager registers a runner assignment with the given
// capabilities and NO wasm anywhere. The gate runs before the module is loaded,
// so a denial never needs a module; an assignment that passes the gate fails
// later with errPluginWasmUnavailable, which is what proves the gate let it
// through rather than that nothing was checked.
func newNotifyTestManager(t *testing.T, capabilities []string) *PluginManager {
	t.Helper()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	t.Cleanup(manager.Stop)

	registerNotifierAssignment(t, manager, notifierAssignmentConfig(notifyAssignmentID, capabilities))

	return manager
}

// notifierAssignmentConfig is the proto assignment the control plane generates
// for a notifier. The capability list is what survived the narrowing funnel
// (`effective_capabilities`), which is why every test states it explicitly
// instead of inheriting a default.
func notifierAssignmentConfig(assignmentID string, capabilities []string) *proto.PluginAssignmentConfig {
	return &proto.PluginAssignmentConfig{
		AssignmentId: assignmentID,
		PluginId:     notifyPluginID,
		PackageId:    notifyPackageID,
		Name:         "Acme Notifier",
		Entrypoint:   "notify_pagerduty",
		Runtime:      "wasi-preview1",
		Enabled:      true,
		TimeoutSec:   5,
		Capabilities: capabilities,
	}
}

func registerNotifierAssignment(
	t *testing.T,
	manager *PluginManager,
	cfg *proto.PluginAssignmentConfig,
) {
	t.Helper()

	assignment := newPluginAssignment(cfg, logger.NewTestLogger())
	runner := newPluginRunner(manager, assignment)
	close(runner.done)

	manager.mu.Lock()
	manager.runners[cfg.AssignmentId] = runner
	manager.mu.Unlock()
}

func newBareNotifyTestManager(t *testing.T) *PluginManager {
	t.Helper()

	manager := NewPluginManager(t.Context(), PluginManagerConfig{
		Logger:        logger.NewTestLogger(),
		CacheDir:      t.TempDir(),
		LocalStoreDir: t.TempDir(),
	})
	t.Cleanup(manager.Stop)

	return manager
}

// The test that stops notify:v1 joining advisory-feed:v1 and
// producer-schedule:v1 on the list of capabilities that are declared in the
// Elixir manifest allowlist and enforced nowhere.
func TestRunActionDeniesNotificationWithoutNotifyCapability(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request", "log", "submit_result"})

	_, err := manager.RunAction(
		t.Context(),
		notifyAssignmentID,
		notificationDeliveryPayload(t),
		5*time.Second,
	)

	if !errors.Is(err, errPluginNotifyCapabilityDenied) {
		t.Fatalf("RunAction error = %v, want %v", err, errPluginNotifyCapabilityDenied)
	}
}

func TestRunActionAdmitsNotificationWithNotifyCapability(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(
		t,
		[]string{"http_request", "log", "submit_result", pluginCapabilityNotify},
	)

	_, err := manager.RunAction(
		t.Context(),
		notifyAssignmentID,
		notificationDeliveryPayload(t),
		5*time.Second,
	)

	if errors.Is(err, errPluginNotifyCapabilityDenied) {
		t.Fatal("an assignment holding notify:v1 must pass the capability gate")
	}
	if !errors.Is(err, errPluginWasmUnavailable) {
		t.Fatalf("RunAction error = %v, want the run to proceed to module load", err)
	}
}

// The gate must not change the behaviour of every other action. An ordinary
// northbound invocation is not a notification and is neither denied nor
// otherwise inspected.
func TestRunActionLeavesNonNotificationActionsUngated(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request"})

	payload := json.RawMessage(`{"invocation_id":"018f2fd1-f0ff-7cf0-9dc0-000000000001",` +
		`"descriptor_id":"fixture.hello.run","input_values":{"reason":"unit-test"}}`)

	_, err := manager.RunAction(t.Context(), notifyAssignmentID, payload, 5*time.Second)

	if errors.Is(err, errPluginNotifyCapabilityDenied) {
		t.Fatal("a non-notification action must not be gated on notify:v1")
	}
	if !errors.Is(err, errPluginWasmUnavailable) {
		t.Fatalf("RunAction error = %v, want the run to proceed to module load", err)
	}
}

// runPluginVerb is the second entrance to plugin execution. Notification
// dispatch is specified to ride plugin.run_action, but a capability with one
// guarded entrance and one unguarded entrance is not enforced.
func TestRunPluginVerbDeniesNotificationWithoutNotifyCapability(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request"})

	_, err := manager.RunPluginVerb(
		t.Context(),
		notifyPluginID,
		notificationDeliveryPayload(t),
		nil,
		5*time.Second,
	)

	if !errors.Is(err, errPluginNotifyCapabilityDenied) {
		t.Fatalf("RunPluginVerb error = %v, want %v", err, errPluginNotifyCapabilityDenied)
	}
}

func TestNotificationEnvelopeRecognition(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		payload   string
		want      bool
		actionKey string
	}{
		{
			name:      "canonical envelope",
			payload:   `{"schema":"serviceradar.notification_delivery.v1","action_key":"pagerduty"}`,
			want:      true,
			actionKey: "pagerduty",
		},
		{
			name:    "unknown forward-compatible fields do not hide the envelope",
			payload: `{"schema":"serviceradar.notification_delivery.v1","future_field":{"a":1}}`,
			want:    true,
		},
		{
			name:    "a different schema version is not this envelope",
			payload: `{"schema":"serviceradar.notification_delivery.v2","action_key":"pagerduty"}`,
			want:    false,
		},
		{
			name:    "an ordinary action invocation",
			payload: `{"invocation_id":"abc","descriptor_id":"fixture.hello.run"}`,
			want:    false,
		},
		{name: "empty payload", payload: "", want: false},
		{name: "whitespace payload", payload: "   ", want: false},
		{name: "malformed json", payload: `{"schema":`, want: false},
		{name: "json that is not an object", payload: `["schema"]`, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			actionKey, ok := pluginActionNotificationEnvelope(json.RawMessage(tt.payload))
			if ok != tt.want {
				t.Fatalf("recognised = %t, want %t", ok, tt.want)
			}
			if actionKey != tt.actionKey {
				t.Fatalf("action key = %q, want %q", actionKey, tt.actionKey)
			}
		})
	}
}

// Fail-closed by construction: everything that is not an explicit grant denies.
func TestDeliversNotificationsIsFailClosed(t *testing.T) {
	t.Parallel()

	var nilAssignment *pluginAssignment
	if nilAssignment.deliversNotifications() {
		t.Fatal("a nil assignment must not deliver notifications")
	}

	if (&pluginAssignment{}).deliversNotifications() {
		t.Fatal("an assignment with no capability map must not deliver notifications")
	}

	denied := &pluginAssignment{Capabilities: map[string]bool{pluginCapabilityNotify: false}}
	if denied.deliversNotifications() {
		t.Fatal("a capability narrowed to false must not deliver notifications")
	}

	granted := &pluginAssignment{Capabilities: map[string]bool{pluginCapabilityNotify: true}}
	if !granted.deliversNotifications() {
		t.Fatal("an assignment holding notify:v1 must deliver notifications")
	}
}

// The envelope schema is a cross-language wire contract. If this constant is
// edited without editing ServiceRadar.Notifications.Dispatcher.edge_command_schema/0,
// the gate stops recognising notification traffic and silently becomes no gate
// at all - the failure mode is a permission that looks enforced and is not.
func TestNotificationEnvelopeSchemaIsPinned(t *testing.T) {
	t.Parallel()

	const want = "serviceradar.notification_delivery.v1"
	if notificationDeliveryEnvelopeSchema != want {
		t.Fatalf("envelope schema = %q, want %q (see dispatcher.ex edge_command_schema/0)",
			notificationDeliveryEnvelopeSchema, want)
	}
}

// --- 3.2.1 addressing and dispatch -----------------------------------------

func TestDecodeNotificationDeliveryReadsAddressingFields(t *testing.T) {
	t.Parallel()

	envelope, ok := decodeNotificationDelivery(notificationDeliveryPayload(t))
	if !ok {
		t.Fatal("the canonical dispatcher envelope must be recognised")
	}

	if envelope.DeliveryID != notifyDeliveryID {
		t.Fatalf("delivery_id = %q, want %q", envelope.DeliveryID, notifyDeliveryID)
	}
	if envelope.ChannelID != notifyChannelID {
		t.Fatalf("channel_id = %q, want %q", envelope.ChannelID, notifyChannelID)
	}
	if envelope.ActionKey != notifyActionKey {
		t.Fatalf("action_key = %q, want %q", envelope.ActionKey, notifyActionKey)
	}
	if envelope.PluginPackageID != notifyPackageID {
		t.Fatalf("plugin_package_id = %q, want %q", envelope.PluginPackageID, notifyPackageID)
	}
	if envelope.PayloadFormat != "json" {
		t.Fatalf("payload_format = %q, want %q", envelope.PayloadFormat, "json")
	}
	if envelope.IsTest {
		t.Fatal("is_test must decode false for an alert-driven delivery")
	}
}

// A delivery core cannot correlate back to its row looks SENT once the command
// is accepted. Refusing it is the cheaper failure.
func TestNotificationDeliveryEnvelopeValidation(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		drop    string
		wantErr bool
	}{
		{name: "complete envelope"},
		{name: "no delivery id", drop: "delivery_id", wantErr: true},
		{name: "no channel id", drop: "channel_id", wantErr: true},
		{name: "no action key", drop: "action_key", wantErr: true},
		{name: "no package id is addressing, not identity", drop: "plugin_package_id"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			extra := map[string]any{}
			if tt.drop != "" {
				extra[tt.drop] = nil
			}

			envelope, ok := decodeNotificationDelivery(notificationDeliveryPayloadWith(t, extra))
			if !ok {
				t.Fatal("envelope must still be recognised as a notification")
			}

			err := envelope.validate()
			if tt.wantErr {
				if !errors.Is(err, errNotificationDeliveryInvalid) {
					t.Fatalf("validate() = %v, want %v", err, errNotificationDeliveryInvalid)
				}
				if !strings.Contains(err.Error(), tt.drop) {
					t.Fatalf("validate() = %v, want the message to name %q", err, tt.drop)
				}
				return
			}
			if err != nil {
				t.Fatalf("validate() = %v, want nil", err)
			}
		})
	}
}

// A NotificationChannel has no plugin_assignment_id column, so the package is
// the address the control plane can actually produce. These cases pin what the
// agent does with each one, and that it never guesses.
func TestResolveNotificationAssignmentID(t *testing.T) {
	t.Parallel()

	t.Run("an explicit assignment id wins", func(t *testing.T) {
		t.Parallel()

		manager := newBareNotifyTestManager(t)
		registerNotifierAssignment(t, manager, notifierAssignmentConfig("assign-a", nil))
		registerNotifierAssignment(t, manager, notifierAssignmentConfig("assign-b", nil))

		envelope, _ := decodeNotificationDelivery(notificationDeliveryPayload(t))

		got, err := manager.resolveNotificationAssignmentID("assign-b", envelope)
		if err != nil {
			t.Fatalf("resolveNotificationAssignmentID() error = %v", err)
		}
		if got != "assign-b" {
			t.Fatalf("assignment = %q, want %q; an exact address must not be re-derived", got, "assign-b")
		}
	})

	t.Run("the package resolves the sole assignment", func(t *testing.T) {
		t.Parallel()

		manager := newBareNotifyTestManager(t)
		registerNotifierAssignment(t, manager, notifierAssignmentConfig(notifyAssignmentID, nil))

		envelope, _ := decodeNotificationDelivery(notificationDeliveryPayload(t))

		got, err := manager.resolveNotificationAssignmentID("", envelope)
		if err != nil {
			t.Fatalf("resolveNotificationAssignmentID() error = %v", err)
		}
		if got != notifyAssignmentID {
			t.Fatalf("assignment = %q, want %q", got, notifyAssignmentID)
		}
	})

	t.Run("an action-only assignment is addressable", func(t *testing.T) {
		t.Parallel()

		// A notifier has no schedule, so the control plane ships it with
		// action-only:v1 and it lands in m.actions rather than m.runners. A
		// resolver that only walked runners would find nothing.
		manager := newBareNotifyTestManager(t)
		assignment := newPluginAssignment(
			notifierAssignmentConfig("assign-action-only", []string{pluginCapabilityActionOnly}),
			logger.NewTestLogger(),
		)
		manager.mu.Lock()
		manager.actions[assignment.AssignmentID] = assignment
		manager.mu.Unlock()

		envelope, _ := decodeNotificationDelivery(notificationDeliveryPayload(t))

		got, err := manager.resolveNotificationAssignmentID("", envelope)
		if err != nil {
			t.Fatalf("resolveNotificationAssignmentID() error = %v", err)
		}
		if got != "assign-action-only" {
			t.Fatalf("assignment = %q, want %q", got, "assign-action-only")
		}
	})

	t.Run("two assignments of one package fail closed", func(t *testing.T) {
		t.Parallel()

		// Two assignments of one package on one agent are two channel
		// configurations - two destinations. Picking either would deliver the
		// alert to the wrong place and record it as sent.
		manager := newBareNotifyTestManager(t)
		registerNotifierAssignment(t, manager, notifierAssignmentConfig("assign-a", nil))
		registerNotifierAssignment(t, manager, notifierAssignmentConfig("assign-b", nil))

		envelope, _ := decodeNotificationDelivery(notificationDeliveryPayload(t))

		_, err := manager.resolveNotificationAssignmentID("", envelope)
		if !errors.Is(err, errNotificationTargetAmbiguous) {
			t.Fatalf("resolveNotificationAssignmentID() error = %v, want %v",
				err, errNotificationTargetAmbiguous)
		}
	})

	t.Run("an unaddressed delivery is refused", func(t *testing.T) {
		t.Parallel()

		manager := newBareNotifyTestManager(t)
		registerNotifierAssignment(t, manager, notifierAssignmentConfig(notifyAssignmentID, nil))

		envelope, _ := decodeNotificationDelivery(
			notificationDeliveryPayloadWith(t, map[string]any{"plugin_package_id": nil}),
		)

		_, err := manager.resolveNotificationAssignmentID("", envelope)
		if !errors.Is(err, errNotificationTargetMissing) {
			t.Fatalf("resolveNotificationAssignmentID() error = %v, want %v",
				err, errNotificationTargetMissing)
		}
	})

	t.Run("a package this agent does not run is not assigned", func(t *testing.T) {
		t.Parallel()

		manager := newBareNotifyTestManager(t)
		envelope, _ := decodeNotificationDelivery(notificationDeliveryPayload(t))

		_, err := manager.resolveNotificationAssignmentID("", envelope)
		if !errors.Is(err, errPluginAssignmentNotFound) {
			t.Fatalf("resolveNotificationAssignmentID() error = %v, want %v",
				err, errPluginAssignmentNotFound)
		}
	})
}

func TestNotificationTargetErrorCodesAreStable(t *testing.T) {
	t.Parallel()

	tests := map[error]string{
		errNotificationTargetMissing:   "missing_notification_target",
		errNotificationTargetAmbiguous: "ambiguous_notification_target",
		errPluginAssignmentNotFound:    "notifier_not_assigned",
		errPluginAdmissionDenied:       "notification_target_unresolved",
	}

	for err, want := range tests {
		if got := notificationTargetErrorCode(err); got != want {
			t.Fatalf("notificationTargetErrorCode(%v) = %q, want %q", err, got, want)
		}
	}
}

// --- 3.2.3 secrets never enter guest memory --------------------------------

// notifierSecretMaterial is the plaintext a broker would resolve. No assertion
// in this file may find it anywhere the guest can read.
const (
	notifierSecretMaterial = "pd-routing-key-DO-NOT-LEAK"
	notifierHostOnlyURL    = "https://hooks.slack.com/services/T000/B000/URL-PATH-SECRET"
)

func notifierCredentialGrant() map[string]any {
	return map[string]any{
		"schema":                "serviceradar.credential_broker_grant.v1",
		"grant_type":            "notification_credential",
		"credential_secret_ref": "credentialref:notification-secret:channel-1",
		"inject": map[string]string{
			"type": "http_header",
			"name": "X-Routing-Key",
		},
		"allow": map[string]any{
			"hosts":   []string{"events.pagerduty.com"},
			"schemes": []string{"https"},
			"methods": []string{http.MethodPost},
			"paths":   []string{"/v2/enqueue"},
		},
	}
}

// The guest config is exactly what hostGetConfig hands back (it returns
// e.configJSON verbatim, and that field has one other writer: the value built
// here). So asserting on it IS asserting on guest memory.
func TestNotificationGuestConfigNeverCarriesCredentialMaterial(t *testing.T) {
	t.Parallel()

	cfg := notifierAssignmentConfig(notifyAssignmentID, []string{
		"get_config", "http_request", "submit_result", pluginCapabilityNotify,
	})
	cfg.ParamsJson = []byte(`{"endpoint_timeout_ms":5000}`)
	// host_params_json is the trusted-host-only proto field. An older agent
	// ignores unknown field 23 entirely; a current one must not surface it
	// through get_config either.
	cfg.HostParamsJson = []byte(`{"webhook_url":"` + notifierHostOnlyURL + `"}`)

	assignment := newPluginAssignment(cfg, logger.NewTestLogger())

	payload := notificationDeliveryPayloadWith(t, map[string]any{
		"credential_broker": notifierCredentialGrant(),
	})

	guestConfig, err := buildActionPluginConfig(assignment.ParamsJSON, payload)
	if err != nil {
		t.Fatalf("buildActionPluginConfig() error = %v", err)
	}

	for _, forbidden := range []string{
		notifierSecretMaterial,
		notifierHostOnlyURL,
		"hooks.slack.com",
		"URL-PATH-SECRET",
		"grant_type",
		"credential_broker",
	} {
		if strings.Contains(string(guestConfig), forbidden) {
			t.Fatalf("guest config exposes %q:\n%s", forbidden, guestConfig)
		}
	}

	// The opaque reference the guest attaches to an outbound request travels in
	// channel_config. The broker grant carrying its authority remains host-only.
	if !strings.Contains(string(guestConfig), "credentialref:notification-secret:channel-1") {
		t.Fatalf("expected the channel secret reference to travel with the invocation:\n%s", guestConfig)
	}

	// And the grant is also extracted host-side, which is what makes injection
	// happen at the HTTP boundary rather than in the guest.
	grants, err := pluginActionCredentialGrants(payload)
	if err != nil {
		t.Fatalf("pluginActionCredentialGrants() error = %v", err)
	}
	if len(grants) != 1 {
		t.Fatalf("host-side grants = %d, want 1", len(grants))
	}

	req, err := http.NewRequestWithContext(
		t.Context(), http.MethodPost, "https://events.pagerduty.com/v2/enqueue", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := applyCredentialBrokerHTTPInjection(req, grants[0], CredentialBrokerMaterial{
		Value: notifierSecretMaterial,
	}); err != nil {
		t.Fatalf("applyCredentialBrokerHTTPInjection() error = %v", err)
	}

	if got := req.Header.Get("X-Routing-Key"); got != notifierSecretMaterial {
		t.Fatalf("injected header = %q, want the resolved material", got)
	}
	if strings.Contains(string(guestConfig), notifierSecretMaterial) {
		t.Fatal("resolving material must not retroactively appear in the guest config")
	}
}

func TestNotificationGuestConfigMatchesNotifierSDKABI(t *testing.T) {
	t.Parallel()

	payload := notificationDeliveryPayloadWith(t, map[string]any{
		"credential_broker": notifierCredentialGrant(),
	})
	guestConfig, err := buildActionPluginConfig([]byte(`{"region":"us"}`), payload)
	if err != nil {
		t.Fatalf("buildActionPluginConfig() error = %v", err)
	}

	var config map[string]any
	if err := json.Unmarshal(guestConfig, &config); err != nil {
		t.Fatalf("decode guest config: %v", err)
	}
	if _, exists := config["action_invocation"]; exists {
		t.Fatal("notifier config must not use the northbound action_invocation discriminator")
	}
	delivery, ok := config[notificationDeliveryConfigKey].(map[string]any)
	if !ok {
		t.Fatalf("notification_delivery = %#v, want object", config[notificationDeliveryConfigKey])
	}
	if got := delivery["schema"]; got != notificationDeliveryRequestSchema {
		t.Fatalf("request schema = %v, want %s", got, notificationDeliveryRequestSchema)
	}
	if _, exists := delivery["credential_broker"]; exists {
		t.Fatal("credential grant must remain host-only")
	}
	if _, exists := delivery["plugin_package_id"]; exists {
		t.Fatal("command addressing must not enter the typed notifier request")
	}
	if got := config["region"]; got != "us" {
		t.Fatalf("plugin config region = %v, want us", got)
	}
}

func TestBuildNotificationPluginConfigRejectsNullPayload(t *testing.T) {
	t.Parallel()

	_, err := buildNotificationPluginConfig(nil, json.RawMessage(`null`))
	if !errors.Is(err, errNotificationDeliveryInvalid) {
		t.Fatalf("buildNotificationPluginConfig() error = %v, want %v", err, errNotificationDeliveryInvalid)
	}
}

func TestNotificationEntrypointOverridesOnlyTheInvocation(t *testing.T) {
	t.Parallel()

	assignment := newPluginAssignment(
		notifierAssignmentConfig(notifyAssignmentID, []string{pluginCapabilityNotify}),
		logger.NewTestLogger(),
	)
	assignment.Entrypoint = "run_check"
	payload := notificationDeliveryPayloadWith(t, map[string]any{
		"entrypoint": "send_opsgenie",
	})

	entrypoint := notificationActionEntrypoint(assignment, payload)
	if entrypoint != "send_opsgenie" {
		t.Fatalf("invocation entrypoint = %q, want send_opsgenie", entrypoint)
	}
	if assignment.Entrypoint != "run_check" {
		t.Fatalf("registered assignment was mutated to %q", assignment.Entrypoint)
	}

	northboundEntrypoint := notificationActionEntrypoint(assignment, json.RawMessage(`{"action":"test"}`))
	if northboundEntrypoint != assignment.Entrypoint {
		t.Fatalf("ordinary action entrypoint = %q, want %q", northboundEntrypoint, assignment.Entrypoint)
	}
}

// --- 3.2.4 the URL-path constraint -----------------------------------------

// The six canonical modes are a cross-language contract with
// ServiceRadar.Plugins.Manifest.@allowed_credential_injection_modes. None of
// them rewrites a URL path, which is the whole reason a Slack or Discord
// incoming webhook cannot run on the edge route.
func TestNotificationCredentialInjectionModesAreTheCanonicalSet(t *testing.T) {
	t.Parallel()

	want := []string{
		"basic_auth",
		"bearer_token",
		"form_urlencoded",
		"http_header",
		"oauth2_client_credentials",
		"oauth2_password_bearer",
		"query",
	}

	got := make([]string, 0, len(notificationCredentialInjectionModes))
	for mode := range notificationCredentialInjectionModes {
		got = append(got, mode)
	}
	sort.Strings(got)

	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("notification injection modes = %v, want %v (see manifest.ex)", got, want)
	}

	if _, ok := notificationCredentialInjectionModes["url_path"]; ok {
		t.Fatal("a url_path injection mode is out of scope for v1 and must be added to the host first")
	}
}

func TestNotificationCredentialGrantsServiceable(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		mode    string
		wantErr bool
	}{
		{name: "http_header", mode: "http_header"},
		{name: "bearer_token", mode: "bearer_token"},
		{name: "basic_auth", mode: "basic_auth"},
		{name: "query", mode: "query"},
		{name: "form_urlencoded", mode: "form_urlencoded"},
		{name: "oauth2_password_bearer", mode: "oauth2_password_bearer"},
		{name: "no injection requested", mode: ""},
		{name: "a url path rewrite is refused", mode: "url_path", wantErr: true},
		{name: "the header shorthand is refused", mode: "header", wantErr: true},
		{name: "the basic_auth shorthand is refused", mode: "http_basic_auth", wantErr: true},
		{name: "the query shorthand is refused", mode: "query_param", wantErr: true},
		{name: "an invented mode is refused", mode: "magic", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			grant := notifierCredentialGrant()
			inject := map[string]string{"name": "X-Routing-Key"}
			if tt.mode != "" {
				inject["type"] = tt.mode
			}
			grant["inject"] = inject

			payload := notificationDeliveryPayloadWith(t, map[string]any{"credential_broker": grant})

			err := notificationCredentialGrantsServiceable(payload)
			if tt.wantErr {
				if !errors.Is(err, errNotificationCredentialInjectionUnsupported) {
					t.Fatalf("error = %v, want %v", err, errNotificationCredentialInjectionUnsupported)
				}
				return
			}
			if err != nil {
				t.Fatalf("error = %v, want nil", err)
			}
		})
	}
}

// The mode allowlist is a security control, so it is enforced at the same
// admission point as notify:v1 - before the module is loaded, on BOTH entrances.
func TestRunActionDeniesNotificationWithUnserviceableInjectionMode(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request", pluginCapabilityNotify})

	grant := notifierCredentialGrant()
	grant["inject"] = map[string]string{"type": "url_path", "name": "webhook"}
	payload := notificationDeliveryPayloadWith(t, map[string]any{"credential_broker": grant})

	_, err := manager.RunAction(t.Context(), notifyAssignmentID, payload, 5*time.Second)
	if !errors.Is(err, errNotificationCredentialInjectionUnsupported) {
		t.Fatalf("RunAction error = %v, want %v", err, errNotificationCredentialInjectionUnsupported)
	}

	_, err = manager.RunPluginVerb(t.Context(), notifyPluginID, payload, nil, 5*time.Second)
	if !errors.Is(err, errNotificationCredentialInjectionUnsupported) {
		t.Fatalf("RunPluginVerb error = %v, want %v", err, errNotificationCredentialInjectionUnsupported)
	}
}

// A grant block that will not decode is not "no grants". Treating it as absent
// is how a credential requirement silently stops being enforced.
func TestNotificationMalformedGrantBlockFailsClosed(t *testing.T) {
	t.Parallel()

	payload := json.RawMessage(`{"schema":"` + notificationDeliveryEnvelopeSchema +
		`","delivery_id":"d","channel_id":"c","action_key":"k","credential_broker":"not-an-object"}`)

	if err := notificationCredentialGrantsServiceable(payload); !errors.Is(err, errNotificationDeliveryInvalid) {
		t.Fatalf("error = %v, want %v", err, errNotificationDeliveryInvalid)
	}
}

// --- 3.2.5 the narrowing funnel --------------------------------------------

// A notifier reaches destinations over HTTP, so "what reaches the agent" is not
// an abstraction: effective_permissions is the only thing standing between a
// notification plugin and an arbitrary host. This pins that the narrowed
// permissions - not the package manifest - are what the host enforces.
func TestNotificationEgressBoundByNarrowedPermissions(t *testing.T) {
	t.Parallel()

	cfg := notifierAssignmentConfig(notifyAssignmentID, []string{
		"http_request", "get_config", "submit_result", pluginCapabilityNotify,
	})
	// The manifest asked for events.pagerduty.com AND api.example.test; package
	// approval then the assignment override narrowed it to the first.
	cfg.PermissionsJson = []byte(
		`{"allowed_domains":["events.pagerduty.com"],"allowed_networks":[],"allowed_ports":[443]}`,
	)

	assignment := newPluginAssignment(cfg, logger.NewTestLogger())

	tests := []struct {
		name    string
		rawURL  string
		allowed bool
	}{
		{name: "the narrowed destination", rawURL: "https://events.pagerduty.com/v2/enqueue", allowed: true},
		{name: "a destination narrowed away", rawURL: "https://api.example.test/v2/enqueue"},
		{name: "an arbitrary host", rawURL: "https://attacker.example.com/collect"},
		{name: "a port narrowed away", rawURL: "https://events.pagerduty.com:8443/v2/enqueue"},
		{name: "plaintext on port 80", rawURL: "http://events.pagerduty.com/v2/enqueue"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			reqURL, err := url.Parse(tt.rawURL)
			if err != nil {
				t.Fatal(err)
			}

			got := pluginHTTPRequestDestinationAllowed(&assignment.Permissions, reqURL)
			if got != tt.allowed {
				t.Fatalf("destination allowed = %t, want %t for %s", got, tt.allowed, tt.rawURL)
			}
		})
	}
}

// Capability narrowing is the other half of the funnel, and it is the half that
// decides whether the notifier runs at all.
func TestNotificationCapabilityReflectsNarrowedAssignment(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name         string
		capabilities []string
		delivers     bool
	}{
		{
			name:         "package approval kept notify:v1",
			capabilities: []string{"http_request", pluginCapabilityNotify},
			delivers:     true,
		},
		{
			name:         "the assignment override dropped notify:v1",
			capabilities: []string{"http_request"},
		},
		{name: "everything was narrowed away"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			assignment := newPluginAssignment(
				notifierAssignmentConfig(notifyAssignmentID, tt.capabilities),
				logger.NewTestLogger(),
			)

			if got := assignment.deliversNotifications(); got != tt.delivers {
				t.Fatalf("deliversNotifications() = %t, want %t", got, tt.delivers)
			}

			// The host capability check and the notification gate must read the
			// same map, or one of them is decorative.
			exec := newPluginExecution(nil, assignment)
			if got := exec.hasCapability(pluginCapabilityNotify); got != tt.delivers {
				t.Fatalf("hasCapability(notify:v1) = %t, want %t", got, tt.delivers)
			}
		})
	}
}

// --- 3.2.1 dispatch through the plugin.run_action command ------------------

func notifyCommandResultPayload(t *testing.T, result *proto.CommandResult) map[string]any {
	t.Helper()

	var payload map[string]any
	if err := json.Unmarshal(result.GetPayloadJson(), &payload); err != nil {
		t.Fatalf("decode command result payload: %v (%s)", err, result.GetPayloadJson())
	}

	return payload
}

func runNotifyCommand(
	t *testing.T,
	manager *PluginManager,
	commandID string,
	payload json.RawMessage,
) *proto.CommandResult {
	t.Helper()

	stream := &fakeControlStreamClient{}
	sender := newControlStreamSender(stream)
	loop := &PushLoop{
		logger: logger.NewTestLogger(),
		server: &Server{pluginManager: manager},
	}

	loop.handleCommand(t.Context(), &proto.CommandRequest{
		CommandId:   commandID,
		CommandType: commandTypePluginRunAction,
		PayloadJson: payload,
	}, sender)

	return waitForCommandResult(t, stream, commandID)
}

func TestNotificationResultStatusControlsOuterCommandSuccess(t *testing.T) {
	t.Parallel()

	envelope := pluginActionResultEnvelope{isNotification: true}
	tests := []struct {
		status string
		want   bool
	}{
		{status: "delivered", want: true},
		{status: "retryable", want: false},
		{status: "failed", want: false},
		{status: "succeeded", want: false},
		{status: "", want: false},
	}

	for _, tt := range tests {
		t.Run(tt.status, func(t *testing.T) {
			t.Parallel()
			payload := map[string]interface{}{
				"schema": notificationDeliveryResultSchema,
				"status": tt.status,
			}
			if got := pluginActionCommandSucceeded(envelope, payload); got != tt.want {
				t.Fatalf("command success for %q = %t, want %t", tt.status, got, tt.want)
			}
		})
	}

	wrongSchema := map[string]interface{}{
		"schema": actionResultAckSchema,
		"status": "delivered",
	}
	if pluginActionCommandSucceeded(envelope, wrongSchema) {
		t.Fatal("a delivered status under the wrong schema must fail closed")
	}
}

func TestNotificationResultRejectsUnsupportedContractMajor(t *testing.T) {
	t.Parallel()

	for _, tt := range []struct {
		name    string
		version any
		failed  bool
	}{
		{name: "supported", version: "1.7.3", failed: false},
		{name: "unsupported", version: "2.0.0", failed: true},
		{name: "malformed", version: "future", failed: true},
		{name: "wrong type", version: 2, failed: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			payload := map[string]interface{}{
				"schema":               notificationDeliveryResultSchema,
				"status":               "delivered",
				"sdk_contract_version": tt.version,
			}

			enforceNotifierContractVersion(payload)
			if tt.failed {
				if payload["status"] != commandStatusFailed || payload["error_class"] != "sdk_contract_mismatch" {
					t.Fatalf("mismatch payload = %#v", payload)
				}
			} else if payload["status"] != "delivered" {
				t.Fatalf("supported payload was changed: %#v", payload)
			}
		})
	}
}

// Notification delivery rides plugin.run_action. There is no second command
// type, and there must never be one: a second type is a second execution mode,
// and a plugin authored for the edge would stop running unchanged on the
// platform-resident agent (design D3).
func TestPluginRunActionDispatchesNotificationByPackage(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{
		"get_config", "http_request", "submit_result", pluginCapabilityNotify,
	})

	result := runNotifyCommand(t, manager, "cmd-notify-dispatch", notificationDeliveryPayload(t))
	payload := notifyCommandResultPayload(t, result)

	// The delivery reached RunAction: it got as far as loading a module, which
	// this fixture has none of. Any addressing failure would have answered
	// before that with one of the target error codes.
	if !strings.Contains(result.GetMessage(), errPluginWasmUnavailable.Error()) {
		t.Fatalf("message = %q, want the run to reach module load", result.GetMessage())
	}
	if got := payload["schema"]; got != notificationDeliveryResultSchema {
		t.Fatalf("schema = %v, want %s", got, notificationDeliveryResultSchema)
	}
	if got := payload["delivery_id"]; got != notifyDeliveryID {
		t.Fatalf("delivery_id = %v, want %s", got, notifyDeliveryID)
	}
	if got := payload["channel_id"]; got != notifyChannelID {
		t.Fatalf("channel_id = %v, want %s", got, notifyChannelID)
	}
	if got := payload["action_key"]; got != notifyActionKey {
		t.Fatalf("action_key = %v, want %s", got, notifyActionKey)
	}
	if _, ok := payload["invocation_id"]; ok {
		t.Fatal("a notification result must not carry northbound invocation identity")
	}
}

// A notification carries no plugin_assignment_id, so the pre-existing
// "missing plugin_assignment_id" guard must not be what answers it. If it is,
// the edge route is dead on arrival and the failure looks like a control-plane
// bug rather than an agent one.
func TestPluginRunActionNotificationIsNotRefusedForMissingAssignmentID(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{pluginCapabilityNotify})

	result := runNotifyCommand(t, manager, "cmd-notify-no-assignment", notificationDeliveryPayload(t))
	payload := notifyCommandResultPayload(t, result)

	if got := payload["error"]; got == "missing_plugin_assignment_id" {
		t.Fatal("a notification must be addressed by package, not refused for a northbound field")
	}
}

func TestPluginRunActionNotificationAddressingFailures(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		payload   func(*testing.T) json.RawMessage
		assigned  []string
		wantError string
	}{
		{
			name: "no addressing at all",
			payload: func(t *testing.T) json.RawMessage {
				t.Helper()
				return notificationDeliveryPayloadWith(t, map[string]any{"plugin_package_id": nil})
			},
			assigned:  []string{notifyAssignmentID},
			wantError: "missing_notification_target",
		},
		{
			name:      "the package is not assigned here",
			payload:   notificationDeliveryPayload,
			wantError: "notifier_not_assigned",
		},
		{
			name:      "two assignments of one package",
			payload:   notificationDeliveryPayload,
			assigned:  []string{"assign-a", "assign-b"},
			wantError: "ambiguous_notification_target",
		},
		{
			name: "an envelope with no delivery identity",
			payload: func(t *testing.T) json.RawMessage {
				t.Helper()
				return notificationDeliveryPayloadWith(t, map[string]any{"delivery_id": nil})
			},
			assigned:  []string{notifyAssignmentID},
			wantError: "invalid_notification_envelope",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			manager := newBareNotifyTestManager(t)
			for _, assignmentID := range tt.assigned {
				registerNotifierAssignment(t, manager, notifierAssignmentConfig(
					assignmentID,
					[]string{pluginCapabilityNotify},
				))
			}

			result := runNotifyCommand(t, manager, "cmd-"+tt.name, tt.payload(t))
			if result.GetSuccess() {
				t.Fatal("an unresolvable notification must not report success")
			}

			payload := notifyCommandResultPayload(t, result)
			if got := payload["error"]; got != tt.wantError {
				t.Fatalf("error = %v, want %q", got, tt.wantError)
			}
			if got := payload["schema"]; got != notificationDeliveryResultSchema {
				t.Fatalf("schema = %v, want %s", got, notificationDeliveryResultSchema)
			}
			if got := payload["delivery_id"]; got != notifyDeliveryID && tt.wantError != "invalid_notification_envelope" {
				t.Fatalf("delivery_id = %v, want %s; a failure core cannot correlate is a timeout",
					got, notifyDeliveryID)
			}
		})
	}
}

// The northbound path must be untouched by all of the above.
func TestPluginRunActionNorthboundResultIsUnchanged(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request"})

	payload := json.RawMessage(`{"schema":"serviceradar.northbound_action_invocation.v1",` +
		`"invocation_id":"inv-1","action_id":"act-1","plugin_assignment_id":"` +
		notifyAssignmentID + `"}`)

	result := runNotifyCommand(t, manager, "cmd-northbound", payload)
	decoded := notifyCommandResultPayload(t, result)

	if got := decoded["schema"]; got != northboundActionResultSchema {
		t.Fatalf("schema = %v, want %s", got, northboundActionResultSchema)
	}
	if got := decoded["invocation_id"]; got != "inv-1" {
		t.Fatalf("invocation_id = %v, want inv-1", got)
	}
	if _, ok := decoded["delivery_id"]; ok {
		t.Fatal("a northbound result must not carry notification identity")
	}
}

func TestPluginRunActionNorthboundStillRequiresAssignmentID(t *testing.T) {
	t.Parallel()

	manager := newNotifyTestManager(t, []string{"http_request"})

	result := runNotifyCommand(t, manager, "cmd-northbound-unaddressed",
		json.RawMessage(`{"invocation_id":"inv-1"}`))
	decoded := notifyCommandResultPayload(t, result)

	if got := decoded["error"]; got != "missing_plugin_assignment_id" {
		t.Fatalf("error = %v, want missing_plugin_assignment_id", got)
	}
}

// --- recognition is a security control, not a convenience ------------------

// A strict decode of the whole envelope would let a payload that CLAIMS this
// schema but carries a wrong-typed field fall through to the ungated northbound
// path - which is a notifier running with no notify:v1 at all. Recognition must
// depend on the discriminator and on nothing else.
func TestNotificationRecognitionSurvivesWrongTypedFields(t *testing.T) {
	t.Parallel()

	payload := json.RawMessage(`{
		"schema":"` + notificationDeliveryEnvelopeSchema + `",
		"delivery_id":"` + notifyDeliveryID + `",
		"channel_id":"` + notifyChannelID + `",
		"action_key":"` + notifyActionKey + `",
		"plugin_package_id":"` + notifyPackageID + `",
		"is_test":123,
		"dedupe_key":{"not":"a string"}
	}`)

	envelope, ok := decodeNotificationDelivery(payload)
	if !ok {
		t.Fatal("a wrong-typed field must not hide the envelope: unrecognised means ungated")
	}
	if envelope.DeliveryID != notifyDeliveryID || envelope.ActionKey != notifyActionKey {
		t.Fatalf("identity fields that DID decode must survive: %+v", envelope)
	}

	// And the gate must actually deny it.
	manager := newNotifyTestManager(t, []string{"http_request"})
	if _, err := manager.RunAction(
		t.Context(), notifyAssignmentID, payload, 5*time.Second,
	); !errors.Is(err, errPluginNotifyCapabilityDenied) {
		t.Fatalf("RunAction error = %v, want %v", err, errPluginNotifyCapabilityDenied)
	}
}

// A wrong type on an IDENTITY field is a refusal, never a bypass.
func TestNotificationWrongTypedIdentityIsRefusedNotBypassed(t *testing.T) {
	t.Parallel()

	payload := json.RawMessage(`{
		"schema":"` + notificationDeliveryEnvelopeSchema + `",
		"delivery_id":42,
		"channel_id":"` + notifyChannelID + `",
		"action_key":"` + notifyActionKey + `"
	}`)

	envelope, ok := decodeNotificationDelivery(payload)
	if !ok {
		t.Fatal("the envelope must still be recognised")
	}
	if err := envelope.validate(); !errors.Is(err, errNotificationDeliveryInvalid) {
		t.Fatalf("validate() = %v, want %v", err, errNotificationDeliveryInvalid)
	}
}

// The discriminator itself is the one field whose type decides recognition: a
// payload that cannot name this schema is not claiming to be a notification.
func TestNotificationRecognitionRequiresAStringSchema(t *testing.T) {
	t.Parallel()

	for _, payload := range []string{
		`{"schema":123,"delivery_id":"d"}`,
		`{"schema":null,"delivery_id":"d"}`,
		`{"delivery_id":"d"}`,
	} {
		if _, ok := decodeNotificationDelivery(json.RawMessage(payload)); ok {
			t.Fatalf("payload %s must not be recognised as a notification", payload)
		}
	}
}
