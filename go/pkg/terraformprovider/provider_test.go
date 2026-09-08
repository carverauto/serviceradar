package terraformprovider

import (
	"context"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"
	"github.com/hashicorp/terraform-plugin-go/tfprotov6"
	"github.com/hashicorp/terraform-plugin-go/tftypes"
)

type protocolHarness struct {
	t        *testing.T
	server   tfprotov6.ProviderServer
	schema   *tfprotov6.Schema
	typeName string
	fixture  *apiFixture
}

func newHarness(t *testing.T, name string) *protocolHarness {
	t.Helper()
	t.Setenv("SERVICERADAR_API_KEY", "")
	t.Setenv("SERVICERADAR_API_TOKEN", "")
	fixture := &apiFixture{}
	api := httptest.NewTLSServer(http.HandlerFunc(fixture.serve))
	t.Cleanup(api.Close)
	server := providerserver.NewProtocol6(New("test")())()
	schemas, err := server.GetProviderSchema(context.Background(), &tfprotov6.GetProviderSchemaRequest{})
	checkRPC(t, err, schemas.Diagnostics)
	if len(schemas.ResourceSchemas) != 4 || len(schemas.DataSourceSchemas) != 4 {
		t.Fatal("expected four resource and data source families")
	}
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw})
	configured, err := server.ConfigureProvider(context.Background(), &tfprotov6.ConfigureProviderRequest{
		Config: dynamic(t, schemas.Provider.ValueType(), map[string]any{"endpoint": api.URL, "api_token": "synthetic-api-token", "ca_certificate": string(ca)}),
	})
	checkRPC(t, err, configured.Diagnostics)
	typeName := "serviceradar_" + name
	return &protocolHarness{t: t, server: server, schema: schemas.ResourceSchemas[typeName], typeName: typeName, fixture: fixture}
}

func dynamic(t *testing.T, typ tftypes.Type, fields map[string]any) *tfprotov6.DynamicValue {
	t.Helper()
	var value tftypes.Value
	if fields == nil {
		value = tftypes.NewValue(typ, nil)
	} else {
		complete := map[string]any{}
		for name := range typ.(tftypes.Object).AttributeTypes {
			complete[name] = fields[name]
		}
		encoded, err := json.Marshal(complete)
		if err != nil {
			t.Fatal(err)
		}
		value, err = tftypes.ValueFromJSON(encoded, typ)
		if err != nil {
			t.Fatal(err)
		}
	}
	result, err := tfprotov6.NewDynamicValue(typ, value)
	if err != nil {
		t.Fatal(err)
	}
	return &result
}

func checkRPC(t *testing.T, err error, diagnostics []*tfprotov6.Diagnostic) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range diagnostics {
		if d.Severity == tfprotov6.DiagnosticSeverityError {
			t.Fatalf("%s: %s", d.Summary, d.Detail)
		}
	}
}

func (h *protocolHarness) object(value *tfprotov6.DynamicValue) tftypes.Value {
	h.t.Helper()
	v, err := value.Unmarshal(h.schema.ValueType())
	if err != nil {
		h.t.Fatal(err)
	}
	return v
}

func (h *protocolHarness) plan(prior, config *tfprotov6.DynamicValue) *tfprotov6.DynamicValue {
	h.t.Helper()
	validated, err := h.server.ValidateResourceConfig(context.Background(), &tfprotov6.ValidateResourceConfigRequest{
		TypeName: h.typeName, Config: config, ClientCapabilities: &tfprotov6.ValidateResourceConfigClientCapabilities{WriteOnlyAttributesAllowed: true},
	})
	checkRPC(h.t, err, validated.Diagnostics)
	// Terraform Core's proposed state uses configuration for managed values and
	// previous state for omitted Optional+Computed attributes. Write-only values
	// are always null in the proposed plan, even though Config carries them.
	var configured, previous map[string]tftypes.Value
	if err := h.object(config).As(&configured); err != nil {
		h.t.Fatal(err)
	}
	if !h.object(prior).IsNull() {
		if err := h.object(prior).As(&previous); err != nil {
			h.t.Fatal(err)
		}
	}
	for _, attribute := range h.schema.Block.Attributes {
		if attribute.WriteOnly {
			configured[attribute.Name] = tftypes.NewValue(attribute.ValueType(), nil)
		} else if attribute.Computed && configured[attribute.Name].IsNull() && previous != nil {
			configured[attribute.Name] = previous[attribute.Name]
		}
	}
	proposed, err := tfprotov6.NewDynamicValue(h.schema.ValueType(), tftypes.NewValue(h.schema.ValueType(), configured))
	if err != nil {
		h.t.Fatal(err)
	}
	before := h.fixture.requests
	planned, err := h.server.PlanResourceChange(context.Background(), &tfprotov6.PlanResourceChangeRequest{TypeName: h.typeName, PriorState: prior, Config: config, ProposedNewState: &proposed})
	checkRPC(h.t, err, planned.Diagnostics)
	if h.fixture.requests != before {
		h.t.Fatal("planning made an HTTP request")
	}
	return planned.PlannedState
}

func (h *protocolHarness) apply(prior, config *tfprotov6.DynamicValue) *tfprotov6.DynamicValue {
	h.t.Helper()
	result, err := h.server.ApplyResourceChange(context.Background(), &tfprotov6.ApplyResourceChangeRequest{
		TypeName: h.typeName, PriorState: prior, Config: config, PlannedState: h.plan(prior, config),
	})
	checkRPC(h.t, err, result.Diagnostics)
	return result.NewState
}

func (h *protocolHarness) read(state *tfprotov6.DynamicValue) *tfprotov6.DynamicValue {
	h.t.Helper()
	result, err := h.server.ReadResource(context.Background(), &tfprotov6.ReadResourceRequest{TypeName: h.typeName, CurrentState: state})
	checkRPC(h.t, err, result.Diagnostics)
	return result.NewState
}

func TestResourceLifecycleProtocol(t *testing.T) {
	configs := map[string]map[string]any{
		"network_credential_secret": {"credential_provider": "awx", "auth_method": "bearer_token", "values_version": 1, "values_wo": map[string]string{"api_token": fixtureMaterial}},
		"network_credential_rule":   {"credential_provider": "awx", "auth_method": "bearer_token", "purpose": "inventory", "scope_type": "agent", "scope_value": fixtureID, "target_query": "in:devices", "secret_id": fixtureID, "allowed_ports": []int{443}},
		"ansible_controller":        {"base_url": "https://awx.example.com", "agent_id": fixtureID, "sync_credential_secret_id": fixtureID},
		"ansible_repository":        {"git_url": "https://git.example.com/automation/playbooks.git"},
	}
	for name, fields := range configs {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t, name)
			fields["name"], fields["idempotency_key"] = "Example configuration", fixtureKey
			config := dynamic(t, h.schema.ValueType(), fields)
			empty := dynamic(t, h.schema.ValueType(), nil)
			state := h.apply(empty, config)
			refreshed := h.read(state)
			if !h.object(state).Equal(h.object(refreshed)) {
				t.Fatal("unchanged refresh changed state")
			}
			if !h.object(refreshed).Equal(h.object(h.plan(refreshed, config))) {
				t.Fatal("second plan is not a no-op")
			}
			if strings.Contains(h.object(state).String(), fixtureMaterial) {
				t.Fatal("secret material entered state")
			}
			if h.fixture.createKey != fixtureKey {
				t.Fatal("create omitted stable idempotency key")
			}
			// Replay the same create after an ambiguous response: stable server ID.
			replayed := h.apply(empty, config)
			if !h.object(state).Equal(h.object(replayed)) {
				t.Fatal("idempotent create changed identity")
			}
			imported, err := h.server.ImportResourceState(context.Background(), &tfprotov6.ImportResourceStateRequest{TypeName: h.typeName, ID: fixtureID})
			checkRPC(t, err, imported.Diagnostics)
			if len(imported.ImportedResources) != 1 {
				t.Fatal("import did not produce one resource")
			}
			importState := h.read(imported.ImportedResources[0].State)
			if h.object(importState).IsNull() {
				t.Fatal("import failed to refresh canonical fields")
			}
			importFields := map[string]any{}
			for key, value := range fields {
				importFields[key] = value
			}
			delete(importFields, "idempotency_key")
			if name == "network_credential_secret" {
				importFields["values_version"] = 0
				delete(importFields, "values_wo")
			}
			if !h.object(importState).Equal(h.object(h.plan(importState, dynamic(t, h.schema.ValueType(), importFields)))) {
				t.Fatal("an imported resource with matching configuration did not produce a no-op plan")
			}
			schemas, err := h.server.GetProviderSchema(context.Background(), &tfprotov6.GetProviderSchemaRequest{})
			checkRPC(t, err, schemas.Diagnostics)
			dataSchema := schemas.DataSourceSchemas[h.typeName]
			observed, err := h.server.ReadDataSource(context.Background(), &tfprotov6.ReadDataSourceRequest{TypeName: h.typeName, Config: dynamic(t, dataSchema.ValueType(), map[string]any{"id": fixtureID})})
			checkRPC(t, err, observed.Diagnostics)
			publicState, err := observed.State.Unmarshal(dataSchema.ValueType())
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(publicState.String(), fixtureMaterial) {
				t.Fatal("data source exposed credential material")
			}
			// A concurrent operator edit is observed, then a fresh plan restores config.
			h.fixture.mu.Lock()
			h.fixture.object["name"] = "Operator edit"
			h.fixture.version++
			h.fixture.mu.Unlock()
			drift := h.read(state)
			if h.object(drift).Equal(h.object(state)) {
				t.Fatal("refresh hid drift")
			}
			state = h.apply(drift, config)
			if !h.object(state).Equal(h.object(h.plan(state, config))) {
				t.Fatal("update did not settle to no-op")
			}
			h.fixture.mu.Lock()
			h.fixture.version++
			h.fixture.mu.Unlock()
			stale, err := h.server.ApplyResourceChange(context.Background(), &tfprotov6.ApplyResourceChangeRequest{TypeName: h.typeName, PriorState: state, PlannedState: empty, Config: empty})
			if err != nil {
				t.Fatal(err)
			}
			if len(stale.Diagnostics) == 0 || h.object(stale.NewState).IsNull() {
				t.Fatal("stale delete falsely removed state")
			}
			state = h.read(state)
			// Destroy must retain state when the API's reference guard rejects it.
			h.fixture.guardDelete = true
			denied, err := h.server.ApplyResourceChange(context.Background(), &tfprotov6.ApplyResourceChangeRequest{TypeName: h.typeName, PriorState: state, PlannedState: empty, Config: empty})
			if err != nil {
				t.Fatal(err)
			}
			if len(denied.Diagnostics) == 0 || h.object(denied.NewState).IsNull() {
				t.Fatal("guarded delete falsely removed state")
			}
			h.fixture.guardDelete = false
			deleted, err := h.server.ApplyResourceChange(context.Background(), &tfprotov6.ApplyResourceChangeRequest{TypeName: h.typeName, PriorState: state, PlannedState: empty, Config: empty})
			checkRPC(t, err, deleted.Diagnostics)
			if !h.object(deleted.NewState).IsNull() {
				t.Fatal("successful delete retained state")
			}
			if !h.object(h.read(state)).IsNull() {
				t.Fatal("404 refresh did not remove missing resource")
			}
		})
	}
}

func TestWriteOnlyRotationAndPartialFailure(t *testing.T) {
	h := newHarness(t, "network_credential_secret")
	fields := map[string]any{"name": "Example credential", "credential_provider": "awx", "auth_method": "bearer_token", "idempotency_key": fixtureKey, "values_version": 1, "values_wo": map[string]string{"api_token": fixtureMaterial}}
	config := dynamic(t, h.schema.ValueType(), fields)
	state := h.apply(dynamic(t, h.schema.ValueType(), nil), config)
	fields["values_wo"] = map[string]string{"api_token": "another-invented-test-value"}
	if !h.object(state).Equal(h.object(h.plan(state, dynamic(t, h.schema.ValueType(), fields)))) {
		t.Fatal("write-only change alone generated a diff")
	}
	fields["values_version"] = 2
	config = dynamic(t, h.schema.ValueType(), fields)
	h.fixture.rejectPatch = true
	failed, err := h.server.ApplyResourceChange(context.Background(), &tfprotov6.ApplyResourceChangeRequest{TypeName: h.typeName, PriorState: state, Config: config, PlannedState: h.plan(state, config)})
	if err != nil {
		t.Fatal(err)
	}
	if len(failed.Diagnostics) == 0 || h.fixture.rotations != 1 {
		t.Fatal("expected one accepted rotation followed by rejected metadata update")
	}
	for _, d := range failed.Diagnostics {
		if strings.Contains(d.Detail, fixtureMaterial) {
			t.Fatal("API response leaked into diagnostics")
		}
	}
	if strings.Contains(h.object(failed.NewState).String(), "another-invented-test-value") {
		t.Fatal("rotation material entered state")
	}
	h.fixture.rejectPatch = false
	state = h.apply(failed.NewState, config)
	if h.fixture.rotations != 1 {
		t.Fatal("retry repeated an accepted credential rotation")
	}
	if !h.object(state).Equal(h.object(h.plan(state, config))) {
		t.Fatal("rotation did not settle to no-op")
	}
}

func TestClientRejectsUnsafeEndpointAndRedactsErrors(t *testing.T) {
	for _, endpoint := range []string{"http://api.example.com", "https://user:password@api.example.com", "https://api.example.com/path", "https://api.example.com?token=secret"} {
		if _, err := newAPIClient(endpoint, "synthetic", "", nil); err == nil {
			t.Fatalf("accepted unsafe endpoint %s", endpoint)
		}
	}
	for _, status := range []int{400, 401, 403, 409, 412, 428, 500} {
		err := (&apiError{status: status}).Error()
		if strings.Contains(err, fixtureMaterial) {
			t.Fatal("error included material")
		}
	}
}

func TestAPIAuthenticationAndResponseGuards(t *testing.T) {
	for _, mode := range []string{"api_key", "api_token"} {
		t.Run(mode, func(t *testing.T) {
			apiToken, apiKey := "", ""
			if mode == "api_key" {
				apiKey = fixtureMaterial
			} else {
				apiToken = fixtureMaterial
			}
			api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				if mode == "api_key" {
					if req.Header.Get("X-API-Key") != fixtureMaterial || req.Header.Get("Authorization") != "" {
						t.Error("API key did not use only X-API-Key")
					}
				} else if req.Header.Get("Authorization") != "Bearer "+fixtureMaterial || req.Header.Get("X-API-Key") != "" {
					t.Error("bearer token did not use only Authorization")
				}
				http.Error(w, fixtureMaterial, http.StatusForbidden)
			}))
			defer api.Close()
			ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw})
			client, err := newAPIClient(api.URL, apiToken, apiKey, ca)
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.request(context.Background(), http.MethodGet, "ansible-controllers/"+fixtureID, "", "", nil)
			if err == nil || strings.Contains(err.Error(), fixtureMaterial) {
				t.Fatal("authentication failure was absent or exposed credential material")
			}
		})
	}
	for _, credentials := range [][2]string{{"", ""}, {fixtureMaterial, fixtureMaterial}, {"bad\ncredential", ""}} {
		_, err := newAPIClient("https://api.example.com", credentials[0], credentials[1], nil)
		if err == nil || strings.Contains(err.Error(), fixtureMaterial) {
			t.Fatal("invalid authentication was accepted or exposed")
		}
	}
	for _, mode := range []string{"missing_etag", "wrong_identity", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			requests := 0
			api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				requests++
				id := fixtureID
				switch mode {
				case "wrong_identity":
					id = fixtureKey
					w.Header().Set("ETag", "\"1\"")
				case "redirect":
					w.Header().Set("Location", "/forwarded")
					w.WriteHeader(http.StatusTemporaryRedirect)
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"id": id})
			}))
			defer api.Close()
			ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw})
			client, err := newAPIClient(api.URL, "", fixtureMaterial, ca)
			if err != nil {
				t.Fatal(err)
			}
			_, err = client.request(context.Background(), http.MethodGet, "ansible-controllers/"+fixtureID, "", "", nil)
			if err == nil {
				t.Fatal("accepted invalid API response")
			}
			if requests != 1 {
				t.Fatal("client followed a redirect or retried")
			}
		})
	}
}
