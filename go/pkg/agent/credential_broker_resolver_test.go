package agent

import (
	"context"
	"errors"
	"testing"

	"github.com/carverauto/serviceradar/proto"
)

type fakeCredentialGrantGateway struct {
	req  *proto.CredentialBrokerResolveRequest
	resp *proto.CredentialBrokerResolveResponse
	err  error
}

func (f *fakeCredentialGrantGateway) ResolveCredentialGrant(
	_ context.Context,
	req *proto.CredentialBrokerResolveRequest,
) (*proto.CredentialBrokerResolveResponse, error) {
	f.req = req
	return f.resp, f.err
}

func TestControlPlaneCredentialBrokerResolverResolvesMaterial(t *testing.T) {
	gateway := &fakeCredentialGrantGateway{
		resp: &proto.CredentialBrokerResolveResponse{
			Success: true,
			Value:   "token-value",
			Fields:  map[string]string{"value": "token-value"},
		},
	}
	resolver := newControlPlaneCredentialBrokerResolver(gateway, "agent-1")

	material, err := resolver.ResolveCredentialGrant(t.Context(), credentialBrokerGrant{
		GrantID:             "grant-1",
		CredentialSecretRef: "credentialref:network-credential-secret:secret-1",
		Consumer: map[string]string{
			"kind":    "northbound_action",
			"id":      "invocation-1",
			"purpose": "launch",
		},
		ResolutionLocation: "agent",
	})
	if err != nil {
		t.Fatalf("ResolveCredentialGrant returned error: %v", err)
	}
	if material.Value != "token-value" || material.Fields["value"] != "token-value" {
		t.Fatalf("material = %#v", material)
	}
	if gateway.req.GetAgentId() != "agent-1" ||
		gateway.req.GetGrantId() != "grant-1" ||
		gateway.req.GetCredentialSecretRef() != "credentialref:network-credential-secret:secret-1" ||
		gateway.req.GetConsumerKind() != "northbound_action" ||
		gateway.req.GetConsumerId() != "invocation-1" ||
		gateway.req.GetPurpose() != "launch" ||
		gateway.req.GetResolutionLocation() != "agent" {
		t.Fatalf("request = %#v", gateway.req)
	}
}

func TestControlPlaneCredentialBrokerResolverDeniesFailedResponse(t *testing.T) {
	gateway := &fakeCredentialGrantGateway{
		resp: &proto.CredentialBrokerResolveResponse{
			Success: false,
			Message: "denied",
		},
	}
	resolver := newControlPlaneCredentialBrokerResolver(gateway, "agent-1")

	_, err := resolver.ResolveCredentialGrant(t.Context(), credentialBrokerGrant{GrantID: "grant-1"})
	if !errors.Is(err, errCredentialBrokerResolutionDenied) {
		t.Fatalf("ResolveCredentialGrant error = %v, want %v", err, errCredentialBrokerResolutionDenied)
	}
}
