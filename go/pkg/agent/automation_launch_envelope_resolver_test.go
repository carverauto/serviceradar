package agent

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/proto"
)

type fakeAutomationLaunchEnvelopeGateway struct {
	request  *proto.AutomationLaunchEnvelopeResolveRequest
	response *proto.AutomationLaunchEnvelopeResolveResponse
	err      error
}

func (f *fakeAutomationLaunchEnvelopeGateway) ResolveAutomationLaunchEnvelope(
	_ context.Context,
	request *proto.AutomationLaunchEnvelopeResolveRequest,
) (*proto.AutomationLaunchEnvelopeResolveResponse, error) {
	f.request = request
	return f.response, f.err
}

func TestAutomationLaunchEnvelopeResolverBindsAgentAndCommand(t *testing.T) {
	responseBearer := encodedToken('b')
	responseIdempotencyKey := idempotencyToken('i')
	commandID := "01980a6d-4a62-7b3f-a249-5f825874ca41"
	grantID := "01980a6d-4a62-7b3f-a249-5f825874ca53"
	reference := launchEnvelopeReferencePrefix + string(encodedToken('r'))
	now := time.Unix(1_752_368_600, 0).UTC()
	gateway := &fakeAutomationLaunchEnvelopeGateway{
		response: &proto.AutomationLaunchEnvelopeResolveResponse{
			Success:         true,
			Bearer:          responseBearer,
			IdempotencyKey:  responseIdempotencyKey,
			CallbackGrantId: grantID,
			ExpiresAtUnix:   1_752_368_700,
		},
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
}

func TestAutomationLaunchEnvelopeResolverDeniesIncompleteOrRejectedResponse(t *testing.T) {
	validGrantID := "01980a6d-4a62-7b3f-a249-5f825874ca53"
	future := time.Now().Add(time.Minute).Unix()
	tests := []struct {
		name     string
		response *proto.AutomationLaunchEnvelopeResolveResponse
	}{
		{name: "nil response"},
		{name: "denied", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: false}},
		{name: "empty bearer", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: true, CallbackGrantId: validGrantID, IdempotencyKey: idempotencyToken('i'), ExpiresAtUnix: future}},
		{name: "empty idempotency key", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: true, CallbackGrantId: validGrantID, Bearer: encodedToken('b'), ExpiresAtUnix: future}},
		{name: "unprefixed idempotency key", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: true, CallbackGrantId: validGrantID, Bearer: encodedToken('b'), IdempotencyKey: encodedToken('i'), ExpiresAtUnix: future}},
		{name: "missing grant", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: true, Bearer: encodedToken('b'), IdempotencyKey: idempotencyToken('i'), ExpiresAtUnix: future}},
		{name: "expired", response: &proto.AutomationLaunchEnvelopeResolveResponse{Success: true, CallbackGrantId: validGrantID, Bearer: encodedToken('b'), IdempotencyKey: idempotencyToken('i'), ExpiresAtUnix: time.Now().Add(-time.Minute).Unix()}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			resolver := newControlPlaneAutomationLaunchEnvelopeResolver(
				&fakeAutomationLaunchEnvelopeGateway{response: test.response},
				"agent-farm01",
			)

			_, err := resolver.Resolve(
				context.Background(),
				launchEnvelopeReferencePrefix+string(encodedToken('r')),
				"01980a6d-4a62-7b3f-a249-5f825874ca41",
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
