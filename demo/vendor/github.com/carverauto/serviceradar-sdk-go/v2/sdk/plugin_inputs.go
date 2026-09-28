package sdk

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	// PluginInputsSchemaV1 is the control-plane payload schema for policy-driven plugin inputs.
	PluginInputsSchemaV1 = "serviceradar.plugin_inputs.v1"
)

var (
	errPluginInputsNilPayload         = errors.New("plugin inputs payload is nil")
	errPluginInputsInvalidSchema      = errors.New("plugin inputs payload has invalid schema")
	errPluginInputsMissingPolicyID    = errors.New("plugin inputs payload missing policy_id")
	errPluginInputsInvalidPolicyVer   = errors.New("plugin inputs payload has invalid policy_version")
	errPluginInputsMissingAgentID     = errors.New("plugin inputs payload missing agent_id")
	errPluginInputsMissingGeneratedAt = errors.New("plugin inputs payload missing generated_at")
	errPluginInputsMissingInputs      = errors.New("plugin inputs payload missing inputs")
	errPluginInputsMissingInputName   = errors.New("plugin inputs payload missing input name")
	errPluginInputsMissingInputEntity = errors.New("plugin inputs payload missing input entity")
	errPluginInputsMissingInputQuery  = errors.New("plugin inputs payload missing input query")
	errPluginInputsInvalidChunkIndex  = errors.New("plugin inputs payload has invalid input chunk_index")
	errPluginInputsInvalidChunkTotal  = errors.New("plugin inputs payload has invalid input chunk_total")
	errPluginInputsMissingInputHash   = errors.New("plugin inputs payload missing input chunk_hash")
	errPluginInputsMissingInputItems  = errors.New("plugin inputs payload missing input items")
)

// PluginInputsPayload is the typed schema for policy-driven plugin input params.
type PluginInputsPayload struct {
	Schema        string         `json:"schema"`
	PolicyID      string         `json:"policy_id"`
	PolicyVersion int            `json:"policy_version"`
	AgentID       string         `json:"agent_id"`
	GeneratedAt   string         `json:"generated_at"`
	Template      map[string]any `json:"template,omitempty"`
	Inputs        []PluginInput  `json:"inputs"`
}

// PluginInput is one named input stream (for example: devices or interfaces).
type PluginInput struct {
	Name       string           `json:"name"`
	Entity     string           `json:"entity"`
	Query      string           `json:"query"`
	ChunkIndex int              `json:"chunk_index"`
	ChunkTotal int              `json:"chunk_total"`
	ChunkHash  string           `json:"chunk_hash"`
	Items      []map[string]any `json:"items"`
}

// PluginInputItem is a flattened item with input metadata attached.
type PluginInputItem struct {
	Name       string
	Entity     string
	Query      string
	ChunkIndex int
	ChunkTotal int
	ChunkHash  string
	Item       map[string]any
}

// CredentialBrokerGrant is a scoped credential broker reference attached to a target.
type CredentialBrokerGrant struct {
	GrantID             string         `json:"grant_id"`
	GrantRef            string         `json:"grant_ref,omitempty"`
	CredentialSecretRef string         `json:"credential_secret_ref,omitempty"`
	GrantType           string         `json:"grant_type,omitempty"`
	Inject              map[string]any `json:"inject,omitempty"`
	ExpiresAt           string         `json:"expires_at,omitempty"`
	CacheStatus         string         `json:"cache_status,omitempty"`
}

// CredentialPolicySnapshot is the redacted credential policy attached to a target item.
type CredentialPolicySnapshot struct {
	CredentialBrokers       []CredentialBrokerGrant `json:"credential_brokers,omitempty"`
	CredentialBrokerGrantID []string                `json:"credential_broker_grant_ids,omitempty"`
}

// TargetContext is a descriptor-aware check target decoded from a plugin input item.
type TargetContext struct {
	UID                 string                   `json:"uid"`
	CheckInstanceID     string                   `json:"check_instance_id"`
	CheckKey            string                   `json:"check_key,omitempty"`
	MonitoringBindingID string                   `json:"monitoring_binding_id,omitempty"`
	DescriptorID        string                   `json:"descriptor_id"`
	DescriptorVersion   string                   `json:"descriptor_version"`
	TargetKind          string                   `json:"target_kind"`
	Target              map[string]any           `json:"target"`
	CredentialPolicy    CredentialPolicySnapshot `json:"credential_policy,omitempty"`
	EventPolicy         map[string]any           `json:"event_policy,omitempty"`
}

// ParsePluginInputsJSON parses and validates a plugin inputs payload JSON document.
func ParsePluginInputsJSON(data []byte) (*PluginInputsPayload, error) {
	var payload PluginInputsPayload
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("decode plugin inputs payload: %w", err)
	}

	if err := payload.Validate(); err != nil {
		return nil, err
	}

	return &payload, nil
}

// TargetContexts decodes descriptor-aware target contexts from all input items.
func (p *PluginInputsPayload) TargetContexts() ([]TargetContext, error) {
	items := p.FlattenItems()
	out := make([]TargetContext, 0, len(items))

	for i, item := range items {
		ctx, err := item.TargetContext()
		if err != nil {
			return nil, fmt.Errorf("decode target context at flattened item %d: %w", i, err)
		}
		out = append(out, ctx)
	}

	return out, nil
}

// TargetContext decodes this input item as a descriptor-aware check target.
func (item PluginInputItem) TargetContext() (TargetContext, error) {
	raw, err := json.Marshal(item.Item)
	if err != nil {
		return TargetContext{}, fmt.Errorf("encode target context: %w", err)
	}

	var ctx TargetContext
	if err := json.Unmarshal(raw, &ctx); err != nil {
		return TargetContext{}, fmt.Errorf("decode target context: %w", err)
	}

	if strings.TrimSpace(ctx.CheckInstanceID) == "" {
		return TargetContext{}, errors.New("target context missing check_instance_id")
	}
	if strings.TrimSpace(ctx.DescriptorID) == "" {
		return TargetContext{}, errors.New("target context missing descriptor_id")
	}
	if ctx.Target == nil {
		ctx.Target = map[string]any{}
	}

	return ctx, nil
}

func (ctx TargetContext) MonitoredServiceID() string {
	return stringFromMap(ctx.Target, "monitored_service_id")
}

func (ctx TargetContext) DeviceUID() string {
	return stringFromMap(ctx.Target, "device_uid")
}

func (ctx TargetContext) EndpointURL() string {
	return stringFromMap(ctx.Target, "endpoint_url")
}

func (ctx TargetContext) Host() string {
	return stringFromMap(ctx.Target, "host")
}

func (ctx TargetContext) Path() string {
	return stringFromMap(ctx.Target, "path")
}

func (ctx TargetContext) Port() int {
	switch value := ctx.Target["port"].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case float64:
		return int(value)
	case json.Number:
		parsed, _ := value.Int64()
		return int(parsed)
	default:
		return 0
	}
}

func (ctx TargetContext) CredentialGrants() []CredentialBrokerGrant {
	return append([]CredentialBrokerGrant(nil), ctx.CredentialPolicy.CredentialBrokers...)
}

// ParsePluginInputsMap parses and validates a plugin inputs payload object.
func ParsePluginInputsMap(m map[string]any) (*PluginInputsPayload, error) {
	raw, err := json.Marshal(m)
	if err != nil {
		return nil, fmt.Errorf("encode plugin inputs map: %w", err)
	}
	return ParsePluginInputsJSON(raw)
}

// Validate checks required schema/fields for a plugin inputs payload.
func (p *PluginInputsPayload) Validate() error {
	if p == nil {
		return errPluginInputsNilPayload
	}

	if strings.TrimSpace(p.Schema) != PluginInputsSchemaV1 {
		return fmt.Errorf("%w: %q", errPluginInputsInvalidSchema, p.Schema)
	}
	if strings.TrimSpace(p.PolicyID) == "" {
		return errPluginInputsMissingPolicyID
	}
	if p.PolicyVersion < 1 {
		return errPluginInputsInvalidPolicyVer
	}
	if strings.TrimSpace(p.AgentID) == "" {
		return errPluginInputsMissingAgentID
	}
	if strings.TrimSpace(p.GeneratedAt) == "" {
		return errPluginInputsMissingGeneratedAt
	}
	if len(p.Inputs) == 0 {
		return errPluginInputsMissingInputs
	}

	for i, in := range p.Inputs {
		if strings.TrimSpace(in.Name) == "" {
			return fmt.Errorf("%w at inputs[%d].name", errPluginInputsMissingInputName, i)
		}
		if strings.TrimSpace(in.Entity) == "" {
			return fmt.Errorf("%w at inputs[%d].entity", errPluginInputsMissingInputEntity, i)
		}
		if strings.TrimSpace(in.Query) == "" {
			return fmt.Errorf("%w at inputs[%d].query", errPluginInputsMissingInputQuery, i)
		}
		if in.ChunkIndex < 0 {
			return fmt.Errorf("%w at inputs[%d].chunk_index", errPluginInputsInvalidChunkIndex, i)
		}
		if in.ChunkTotal < 1 {
			return fmt.Errorf("%w at inputs[%d].chunk_total", errPluginInputsInvalidChunkTotal, i)
		}
		if strings.TrimSpace(in.ChunkHash) == "" {
			return fmt.Errorf("%w at inputs[%d].chunk_hash", errPluginInputsMissingInputHash, i)
		}
		if len(in.Items) == 0 {
			return fmt.Errorf("%w at inputs[%d].items", errPluginInputsMissingInputItems, i)
		}
	}

	return nil
}

// FlattenItems flattens all input items while preserving deterministic payload order.
func (p *PluginInputsPayload) FlattenItems() []PluginInputItem {
	if p == nil || len(p.Inputs) == 0 {
		return nil
	}

	out := make([]PluginInputItem, 0)
	for _, in := range p.Inputs {
		for _, item := range in.Items {
			out = append(out, PluginInputItem{
				Name:       in.Name,
				Entity:     in.Entity,
				Query:      in.Query,
				ChunkIndex: in.ChunkIndex,
				ChunkTotal: in.ChunkTotal,
				ChunkHash:  in.ChunkHash,
				Item:       item,
			})
		}
	}
	return out
}

// EachItem iterates every item in payload order until callback returns an error.
func (p *PluginInputsPayload) EachItem(fn func(PluginInputItem) error) error {
	if fn == nil {
		return nil
	}
	for _, item := range p.FlattenItems() {
		if err := fn(item); err != nil {
			return err
		}
	}
	return nil
}

// ItemsByEntity returns all flattened items for the specified entity.
func (p *PluginInputsPayload) ItemsByEntity(entity string) []PluginInputItem {
	entity = strings.TrimSpace(strings.ToLower(entity))
	if entity == "" {
		return nil
	}

	out := make([]PluginInputItem, 0)
	for _, item := range p.FlattenItems() {
		if strings.ToLower(strings.TrimSpace(item.Entity)) == entity {
			out = append(out, item)
		}
	}
	return out
}

// ItemsByName returns all flattened items for the specified input name.
func (p *PluginInputsPayload) ItemsByName(name string) []PluginInputItem {
	name = strings.TrimSpace(strings.ToLower(name))
	if name == "" {
		return nil
	}

	out := make([]PluginInputItem, 0)
	for _, item := range p.FlattenItems() {
		if strings.ToLower(strings.TrimSpace(item.Name)) == name {
			out = append(out, item)
		}
	}
	return out
}

func stringFromMap(m map[string]any, key string) string {
	value, ok := m[key]
	if !ok {
		return ""
	}

	switch typed := value.(type) {
	case string:
		return typed
	case fmt.Stringer:
		return typed.String()
	default:
		return fmt.Sprint(typed)
	}
}
