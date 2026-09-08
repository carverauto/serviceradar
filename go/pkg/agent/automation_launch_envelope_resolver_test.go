package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/go/pkg/agentgateway"
	"github.com/carverauto/serviceradar/go/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

const (
	testAutomationLaunchCommandID    = "01980a6d-4a62-7b3f-a249-5f825874ca41"
	testAutomationLaunchGrantID      = "01980a6d-4a62-7b3f-a249-5f825874ca53"
	testAutomationLaunchMismatchedID = "01980a6d-4a62-7b3f-a249-5f825874ca99"
)

type fakeAutomationLaunchEnvelopeGateway struct {
	request   *proto.AutomationLaunchEnvelopeResolveRequest
	response  *proto.AutomationLaunchEnvelopeResolveResponse
	err       error
	calls     int
	singleUse bool
}

func (f *fakeAutomationLaunchEnvelopeGateway) ResolveAutomationLaunchEnvelope(
	_ context.Context,
	request *proto.AutomationLaunchEnvelopeResolveRequest,
) (*proto.AutomationLaunchEnvelopeResolveResponse, error) {
	f.calls++
	f.request = request
	if f.singleUse && f.calls > 1 {
		return nil, errAutomationLaunchEnvelopeDenied
	}
	return f.response, f.err
}

func TestAutomationLaunchEnvelopeResolverBindsAgentAndCommand(t *testing.T) {
	commandID := testAutomationLaunchCommandID
	grantID := testAutomationLaunchGrantID
	reference := launchEnvelopeReferencePrefix + string(encodedToken('r'))
	now := time.Unix(1_752_368_600, 0).UTC()
	response := validAutomationLaunchEnvelopeResponse(now.Add(100*time.Second), commandID, grantID)
	responseBearer := response.Bearer
	responseIdempotencyKey := response.IdempotencyKey
	gateway := &fakeAutomationLaunchEnvelopeGateway{
		response: response,
	}
	resolver := newControlPlaneAutomationLaunchEnvelopeResolver(gateway, " agent-farm01 ")
	resolver.now = func() time.Time { return now }

	material, err := resolver.Resolve(context.Background(), reference, commandID)
	if err != nil {
		t.Fatalf("resolve launch envelope: %v", err)
	}
	defer material.Destroy()

	if gateway.request.GetAgentId() != "agent-farm01" {
		t.Fatalf("expected authenticated agent correlation, got %q", gateway.request.GetAgentId())
	}
	if gateway.request.GetEnvelopeRef() != reference || gateway.request.GetCommandId() != commandID {
		t.Fatalf("unexpected resolver request: %#v", gateway.request)
	}
	if string(material.Bearer) != string(encodedToken('b')) {
		t.Fatal("resolved bearer mismatch")
	}
	if material.CallbackGrantID != grantID {
		t.Fatalf("callback grant mismatch: %q", material.CallbackGrantID)
	}
	if string(material.IdempotencyKey) != string(idempotencyToken('i')) {
		t.Fatal("resolved idempotency key mismatch")
	}
	if !material.ExpiresAt.Equal(time.Unix(1_752_368_700, 0).UTC()) {
		t.Fatalf("expiry mismatch: %s", material.ExpiresAt)
	}
	if string(material.CallbackURL) != expectedCallbackURL(grantID) ||
		string(material.CallbackAllowedOrigin) != "https://demo.example.com" ||
		string(material.ManifestSHA256) != repeatedByte('a', 64) ||
		string(material.SCMRevision) != repeatedByte('b', 40) ||
		string(material.ContentSHA256) != repeatedByte('c', 64) ||
		string(material.CallbackPhase) != "stage" ||
		string(material.CallbackOperation) != "enroll" ||
		string(material.CallbackState) != "present" {
		t.Fatalf("resolved callback metadata mismatch: %#v", material)
	}
	if material.CallbackCredentialTypeID != 91 || material.CallbackCredentialOrganizationID != 2 ||
		string(material.CallbackCredentialInjectorSHA256) != repeatedByte('d', 64) {
		t.Fatalf("resolved callback credential correlation mismatch: %#v", material)
	}

	for index, value := range responseBearer {
		if value != 0 {
			t.Fatalf("response bearer byte %d was not cleared", index)
		}
	}
	for index, value := range responseIdempotencyKey {
		if value != 0 {
			t.Fatalf("response idempotency byte %d was not cleared", index)
		}
	}
	for _, buffer := range automationLaunchEnvelopeResponseBuffers(response) {
		if !allZero(buffer) {
			t.Fatal("protobuf response metadata buffer was not cleared")
		}
	}
}

func TestAutomationLaunchEnvelopeResolverDeniesIncompleteOrRejectedResponse(t *testing.T) {
	validGrantID := testAutomationLaunchGrantID
	commandID := testAutomationLaunchCommandID
	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		mutate func(*proto.AutomationLaunchEnvelopeResolveResponse)
	}{
		{name: "nil response"},
		{name: "denied", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.Success = false }},
		{name: "empty bearer", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.Bearer = nil }},
		{name: "empty idempotency key", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.IdempotencyKey = nil }},
		{name: "unprefixed idempotency key", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.IdempotencyKey = encodedToken('i') }},
		{name: "missing grant", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.CallbackGrantId = "" }},
		{name: "expired", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.ExpiresAtUnix = now.Add(-time.Minute).Unix()
		}},
		{name: "excess ttl", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.ExpiresAtUnix = now.Add(11 * time.Minute).Unix()
		}},
		{name: "wrong agent", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.DispatchAgentId = "agent-other" }},
		{name: "wrong command", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.CommandId = testAutomationLaunchMismatchedID
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var response *proto.AutomationLaunchEnvelopeResolveResponse
			if test.name != "nil response" {
				response = validAutomationLaunchEnvelopeResponse(now.Add(5*time.Minute), commandID, validGrantID)
				if test.mutate != nil {
					test.mutate(response)
				}
			}
			resolver := newControlPlaneAutomationLaunchEnvelopeResolver(
				&fakeAutomationLaunchEnvelopeGateway{response: response},
				"agent-farm01",
			)
			resolver.now = func() time.Time { return now }

			_, err := resolver.Resolve(
				context.Background(),
				launchEnvelopeReferencePrefix+string(encodedToken('r')),
				commandID,
			)
			if !errors.Is(err, errAutomationLaunchEnvelopeDenied) {
				t.Fatalf("expected denied error, got %v", err)
			}
		})
	}
}

func encodedToken(value byte) []byte {
	encoded := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{value}, 32))
	return []byte(encoded)
}

func idempotencyToken(value byte) []byte {
	return append([]byte(callbackIdempotencyKeyPrefix), encodedToken(value)...)
}

func TestAutomationLaunchEnvelopeMaterialDestroyClearsBearer(t *testing.T) {
	bearer := []byte("bearer-in-memory")
	idempotencyKey := []byte("idempotency-in-memory")
	material := AutomationLaunchEnvelopeMaterial{Bearer: bearer, IdempotencyKey: idempotencyKey}
	material.Destroy()

	if material.Bearer != nil {
		t.Fatal("destroy must release bearer slice")
	}
	if material.IdempotencyKey != nil {
		t.Fatal("destroy must release idempotency key slice")
	}
	for index, value := range bearer {
		if value != 0 {
			t.Fatalf("bearer byte %d was not cleared", index)
		}
	}
	for index, value := range idempotencyKey {
		if value != 0 {
			t.Fatalf("idempotency key byte %d was not cleared", index)
		}
	}
}

func TestAutomationLaunchEnvelopeResolverBridgesExactAWXMaterialOnce(t *testing.T) {
	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	commandID := testAutomationLaunchCommandID
	grantID := testAutomationLaunchGrantID
	reference := launchEnvelopeReferencePrefix + string(encodedToken('r'))
	response := validAutomationLaunchEnvelopeResponse(now.Add(5*time.Minute), commandID, grantID)
	responseBuffers := automationLaunchEnvelopeResponseBuffers(response)
	gateway := &fakeAutomationLaunchEnvelopeGateway{response: response, singleUse: true}
	resolver := newControlPlaneAutomationLaunchEnvelopeResolver(gateway, "agent-farm01")
	resolver.now = func() time.Time { return now }
	binding := validAWXBridgeBinding(reference, commandID)

	material, err := resolver.ResolveAWXCallbackCredentialEnvelope(t.Context(), binding)
	if err != nil {
		t.Fatalf("resolve AWX callback envelope: %v", err)
	}
	if string(material.CallbackGrant) != string(encodedToken('b')) ||
		string(material.CallbackIdempotencyKey) != string(idempotencyToken('i')) ||
		string(material.CallbackURL) != expectedCallbackURL(grantID) ||
		string(material.CallbackAllowedOrigin) != "https://demo.example.com" ||
		string(material.CallbackManifestSHA256) != repeatedByte('a', 64) ||
		string(material.SCMRevision) != repeatedByte('b', 40) ||
		string(material.ContentSHA256) != repeatedByte('c', 64) ||
		string(material.CallbackPhase) != "stage" ||
		string(material.CallbackOperation) != "enroll" ||
		string(material.CallbackState) != "present" {
		t.Fatalf("unexpected AWX material: %#v", material)
	}
	for _, buffer := range responseBuffers {
		if !allZero(buffer) {
			t.Fatal("intermediate protobuf buffer was not zeroed")
		}
	}

	finalBuffers := [][]byte{
		material.CallbackGrant,
		material.CallbackIdempotencyKey,
		material.CallbackURL,
		material.CallbackAllowedOrigin,
		material.CallbackManifestSHA256,
		material.SCMRevision,
		material.ContentSHA256,
		material.CallbackPhase,
		material.CallbackOperation,
		material.CallbackState,
	}
	material.destroy()
	for _, buffer := range finalBuffers {
		if !allZero(buffer) {
			t.Fatal("final AWX callback material was not zeroed")
		}
	}

	if _, err := resolver.ResolveAWXCallbackCredentialEnvelope(t.Context(), binding); !errors.Is(err, errAWXCallbackCredentialResolutionDenied) {
		t.Fatalf("expected single-use denial, got %v", err)
	}
	if gateway.calls != 2 {
		t.Fatalf("gateway calls = %d, want two attempts with one release", gateway.calls)
	}
}

func TestAutomationLaunchEnvelopeResolverRejectsAWXBindingOrMetadataTamper(t *testing.T) {
	now := time.Date(2026, 7, 13, 1, 0, 0, 0, time.UTC)
	commandID := testAutomationLaunchCommandID
	grantID := testAutomationLaunchGrantID
	reference := launchEnvelopeReferencePrefix + string(encodedToken('r'))

	bindingMutations := []struct {
		name   string
		mutate func(*AWXCallbackCredentialBinding)
	}{
		{name: "dispatch agent", mutate: func(value *AWXCallbackCredentialBinding) { value.DispatchAgentID = "agent-other" }},
		{name: "command", mutate: func(value *AWXCallbackCredentialBinding) { value.CommandID = testAutomationLaunchMismatchedID }},
		{name: "controller", mutate: func(value *AWXCallbackCredentialBinding) { value.ControllerID = testAutomationLaunchMismatchedID }},
		{name: "child execution", mutate: func(value *AWXCallbackCredentialBinding) {
			value.ChildExecutionID = testAutomationLaunchMismatchedID
		}},
		{name: "inventory", mutate: func(value *AWXCallbackCredentialBinding) { value.InventoryID++ }},
		{name: "template", mutate: func(value *AWXCallbackCredentialBinding) { value.JobTemplateID++ }},
		{name: "credential type", mutate: func(value *AWXCallbackCredentialBinding) { value.CredentialTypeID++ }},
		{name: "organization", mutate: func(value *AWXCallbackCredentialBinding) { value.OrganizationID++ }},
		{name: "injector", mutate: func(value *AWXCallbackCredentialBinding) { value.InjectorSHA256 = repeatedByte('e', 64) }},
	}

	for _, test := range bindingMutations {
		t.Run("binding "+test.name, func(t *testing.T) {
			binding := validAWXBridgeBinding(reference, commandID)
			test.mutate(&binding)
			response := validAutomationLaunchEnvelopeResponse(now.Add(5*time.Minute), commandID, grantID)
			resolver := newControlPlaneAutomationLaunchEnvelopeResolver(
				&fakeAutomationLaunchEnvelopeGateway{response: response},
				"agent-farm01",
			)
			resolver.now = func() time.Time { return now }

			if _, err := resolver.ResolveAWXCallbackCredentialEnvelope(t.Context(), binding); !errors.Is(err, errAWXCallbackCredentialResolutionDenied) {
				t.Fatalf("expected binding denial, got %v", err)
			}
		})
	}

	responseMutations := []struct {
		name   string
		mutate func(*proto.AutomationLaunchEnvelopeResolveResponse)
	}{
		{name: "callback URL", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.CallbackUrl = []byte("https://demo.example.com/wrong")
		}},
		{name: "allowed origin", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.CallbackAllowedOrigin = []byte("https://other.example.com")
		}},
		{name: "manifest", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) {
			value.ManifestSha256 = []byte(repeatedByte('z', 64))
		}},
		{name: "phase", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.CallbackPhase = []byte("arbitrary") }},
		{name: "state", mutate: func(value *proto.AutomationLaunchEnvelopeResolveResponse) { value.CallbackState = []byte("absent") }},
	}

	for _, test := range responseMutations {
		t.Run("metadata "+test.name, func(t *testing.T) {
			response := validAutomationLaunchEnvelopeResponse(now.Add(5*time.Minute), commandID, grantID)
			test.mutate(response)
			buffers := automationLaunchEnvelopeResponseBuffers(response)
			resolver := newControlPlaneAutomationLaunchEnvelopeResolver(
				&fakeAutomationLaunchEnvelopeGateway{response: response},
				"agent-farm01",
			)
			resolver.now = func() time.Time { return now }

			if _, err := resolver.ResolveAWXCallbackCredentialEnvelope(
				t.Context(),
				validAWXBridgeBinding(reference, commandID),
			); !errors.Is(err, errAWXCallbackCredentialResolutionDenied) {
				t.Fatalf("expected metadata denial, got %v", err)
			}
			for _, buffer := range buffers {
				if !allZero(buffer) {
					t.Fatal("failure path retained protobuf callback material")
				}
			}
		})
	}
}

func TestNewPushLoopInstallsAWXCallbackEnvelopeResolver(t *testing.T) {
	manager := NewPluginManager(t.Context(), PluginManagerConfig{Logger: logger.NewTestLogger()})
	defer manager.Stop()
	server := &Server{
		config:        &ServerConfig{AgentID: "agent-farm01"},
		pluginManager: manager,
		logger:        logger.NewTestLogger(),
	}
	gateway := agentgateway.NewGatewayClient("127.0.0.1:50051", nil, logger.NewTestLogger())

	_ = NewPushLoop(server, gateway, time.Second, logger.NewTestLogger())

	installed := manager.awxCallbackCredentialEnvelopeResolver()
	resolver, ok := installed.(*controlPlaneAutomationLaunchEnvelopeResolver)
	if !ok || resolver == nil {
		t.Fatalf("AWX callback resolver was not installed: %#v", installed)
	}
	if resolver != server.launchEnvelopes || resolver.agentID != "agent-farm01" {
		t.Fatal("PluginManager and Server did not receive the same selected-agent resolver")
	}
}

func validAutomationLaunchEnvelopeResponse(
	expiresAt time.Time,
	commandID string,
	grantID string,
) *proto.AutomationLaunchEnvelopeResolveResponse {
	return &proto.AutomationLaunchEnvelopeResolveResponse{
		Success:                          true,
		Bearer:                           encodedToken('b'),
		IdempotencyKey:                   idempotencyToken('i'),
		CallbackGrantId:                  grantID,
		ExpiresAtUnix:                    expiresAt.Unix(),
		CallbackUrl:                      []byte(expectedCallbackURL(grantID)),
		CallbackAllowedOrigin:            []byte("https://demo.example.com"),
		ManifestSha256:                   []byte(repeatedByte('a', 64)),
		ScmRevision:                      []byte(repeatedByte('b', 40)),
		ContentSha256:                    []byte(repeatedByte('c', 64)),
		CallbackPhase:                    []byte("stage"),
		CallbackOperation:                []byte("enroll"),
		CallbackState:                    []byte("present"),
		ControllerId:                     "01980a6d-4a62-7b3f-a249-5f825874ca44",
		InventoryId:                      17,
		JobTemplateId:                    23,
		CallbackCredentialTypeId:         91,
		CallbackCredentialOrganizationId: 2,
		CallbackCredentialInjectorSha256: []byte(repeatedByte('d', 64)),
		DispatchAgentId:                  "agent-farm01",
		ChildExecutionId:                 "01980a6d-4a62-7b3f-a249-5f825874ca42",
		CommandId:                        commandID,
	}
}

func validAWXBridgeBinding(reference, commandID string) AWXCallbackCredentialBinding {
	return AWXCallbackCredentialBinding{
		Schema:           awxCallbackCredentialBindingSchema,
		EnvelopeRef:      reference,
		DispatchAgentID:  "agent-farm01",
		ControllerID:     "01980a6d-4a62-7b3f-a249-5f825874ca44",
		ChildExecutionID: "01980a6d-4a62-7b3f-a249-5f825874ca42",
		InventoryID:      17,
		JobTemplateID:    23,
		CredentialTypeID: 91,
		OrganizationID:   2,
		CredentialName:   awxCallbackCredentialNamePrefix + "01980a6d-4a62-7b3f-a249-5f825874ca42",
		CredentialSlot:   awxCallbackCredentialSlot,
		InjectorSHA256:   repeatedByte('d', 64),
		CommandID:        commandID,
	}
}

func expectedCallbackURL(grantID string) string {
	return "https://demo.example.com/api/v1/automation/callback-grants/" + grantID +
		"/actions/remote_access.ssh_ca.bundle.read"
}
