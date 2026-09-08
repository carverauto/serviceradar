package sdk

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

const (
	ActionInvocationSchemaV1 = "serviceradar.northbound_action_invocation.v1"
	ActionResultSchemaV1     = "serviceradar.northbound_action_result.v1"
)

type ActionScope string

const (
	ActionScopeDevice    ActionScope = "device"
	ActionScopeInterface ActionScope = "interface"
	ActionScopeEvent     ActionScope = "event"
)

type ActionSafety string

const (
	ActionSafetyReadOnly    ActionSafety = "read_only"
	ActionSafetyStandard    ActionSafety = "standard"
	ActionSafetyDestructive ActionSafety = "destructive"
)

type ActionStatus string

const (
	ActionStatusSucceeded  ActionStatus = "succeeded"
	ActionStatusFailed     ActionStatus = "failed"
	ActionStatusSkipped    ActionStatus = "skipped"
	ActionStatusSuppressed ActionStatus = "suppressed"
	ActionStatusDeferred   ActionStatus = "deferred"
	ActionStatusPolling    ActionStatus = "polling"
	ActionStatusFetching   ActionStatus = "result_fetching"
	ActionStatusExpired    ActionStatus = "expired"
)

type ActionPollMode string

const (
	ActionPollModePoll    ActionPollMode = "poll"
	ActionPollModeWebhook ActionPollMode = "webhook"
)

type ActionCallback struct {
	JobID       string `json:"job_id,omitempty"`
	Path        string `json:"path,omitempty"`
	URL         string `json:"url,omitempty"`
	Token       string `json:"token,omitempty"`
	TokenHeader string `json:"token_header,omitempty"`
}

// ActionDescriptor describes a northbound action exported from plugin.yaml.
type ActionDescriptor struct {
	ActionID               string         `json:"action_id"`
	Version                string         `json:"version,omitempty"`
	Label                  string         `json:"label"`
	Description            string         `json:"description,omitempty"`
	Scopes                 []ActionScope  `json:"scopes"`
	RequiredContext        []string       `json:"required_context,omitempty"`
	InputSchema            map[string]any `json:"input_schema,omitempty"`
	TimeoutSeconds         int            `json:"timeout_seconds,omitempty"`
	SafetyClassification   ActionSafety   `json:"safety_classification,omitempty"`
	RequiresConfirmation   bool           `json:"requires_confirmation,omitempty"`
	CredentialRequirements map[string]any `json:"credential_requirements,omitempty"`
	ResultSchemaVersion    string         `json:"result_schema_version,omitempty"`
}

func NewActionDescriptor(actionID, label string, scopes ...ActionScope) *ActionDescriptor {
	return &ActionDescriptor{
		ActionID:             actionID,
		Version:              "1.0.0",
		Label:                label,
		Scopes:               scopes,
		TimeoutSeconds:       60,
		SafetyClassification: ActionSafetyStandard,
		ResultSchemaVersion:  ActionResultSchemaV1,
	}
}

func (d *ActionDescriptor) WithVersion(version string) *ActionDescriptor {
	d.Version = version
	return d
}

func (d *ActionDescriptor) WithDescription(description string) *ActionDescriptor {
	d.Description = description
	return d
}

func (d *ActionDescriptor) WithRequiredContext(fields ...string) *ActionDescriptor {
	d.RequiredContext = fields
	return d
}

func (d *ActionDescriptor) WithInputSchema(schema map[string]any) *ActionDescriptor {
	d.InputSchema = schema
	return d
}

func (d *ActionDescriptor) WithTimeoutSeconds(seconds int) *ActionDescriptor {
	d.TimeoutSeconds = seconds
	return d
}

func (d *ActionDescriptor) WithSafety(classification ActionSafety) *ActionDescriptor {
	d.SafetyClassification = classification
	return d
}

func (d *ActionDescriptor) WithConfirmationRequired(required bool) *ActionDescriptor {
	d.RequiresConfirmation = required
	return d
}

func (d *ActionDescriptor) WithCredentialRequirements(requirements map[string]any) *ActionDescriptor {
	d.CredentialRequirements = requirements
	return d
}

// ActionInvocation is the host-provided payload for plugin.run_action.
type ActionInvocation struct {
	SchemaVersion         string                 `json:"schema"`
	Phase                 string                 `json:"phase,omitempty"`
	InvocationID          string                 `json:"invocation_id"`
	InvocationTargetID    string                 `json:"invocation_target_id,omitempty"`
	ProviderID            string                 `json:"provider_id,omitempty"`
	DescriptorID          string                 `json:"descriptor_id,omitempty"`
	ActionID              string                 `json:"action_id"`
	ActionVersion         string                 `json:"action_version,omitempty"`
	DescriptorHash        string                 `json:"descriptor_hash,omitempty"`
	ResultSchemaVersion   string                 `json:"result_schema_version,omitempty"`
	PluginAssignmentID    string                 `json:"plugin_assignment_id,omitempty"`
	PluginPackageID       string                 `json:"plugin_package_id,omitempty"`
	Targets               []ActionTargetSnapshot `json:"targets,omitempty"`
	InputValues           map[string]any         `json:"input_values,omitempty"`
	RedactedInputValues   map[string]any         `json:"redacted_input_values,omitempty"`
	ContinuationState     map[string]any         `json:"continuation_state,omitempty"`
	ExternalCorrelationID string                 `json:"external_correlation_id,omitempty"`
	PollAttemptCount      int                    `json:"poll_attempt_count,omitempty"`
	RequestedAt           string                 `json:"requested_at,omitempty"`
	Metadata              map[string]any         `json:"metadata,omitempty"`
}

// ActionTargetSnapshot is the immutable device/interface/event target selected at launch time.
type ActionTargetSnapshot struct {
	Kind             string         `json:"kind"`
	NorthboundJobID  string         `json:"northbound_job_id,omitempty"`
	Callback         ActionCallback `json:"callback,omitempty"`
	DeviceUID        string         `json:"device_uid,omitempty"`
	DeviceName       string         `json:"device_name,omitempty"`
	Name             string         `json:"name,omitempty"`
	Hostname         string         `json:"hostname,omitempty"`
	DeviceHostname   string         `json:"device_hostname,omitempty"`
	IP               string         `json:"ip,omitempty"`
	DeviceIP         string         `json:"device_ip,omitempty"`
	MAC              string         `json:"mac,omitempty"`
	VendorName       string         `json:"vendor_name,omitempty"`
	Model            string         `json:"model,omitempty"`
	Type             string         `json:"type,omitempty"`
	IsAvailable      *bool          `json:"is_available,omitempty"`
	AgentID          string         `json:"agent_id,omitempty"`
	GatewayID        string         `json:"gateway_id,omitempty"`
	DeviceAgentID    string         `json:"device_agent_id,omitempty"`
	DeviceGatewayID  string         `json:"device_gateway_id,omitempty"`
	DiscoverySources []string       `json:"discovery_sources,omitempty"`
	InterfaceUID     string         `json:"interface_uid,omitempty"`
	IfIndex          *int           `json:"if_index,omitempty"`
	IfName           string         `json:"if_name,omitempty"`
	IfDescr          string         `json:"if_descr,omitempty"`
	IfAlias          string         `json:"if_alias,omitempty"`
	IfPhysAddress    string         `json:"if_phys_address,omitempty"`
	IPAddresses      []string       `json:"ip_addresses,omitempty"`
	IfAdminStatus    string         `json:"if_admin_status,omitempty"`
	IfOperStatus     string         `json:"if_oper_status,omitempty"`
	IfTypeName       string         `json:"if_type_name,omitempty"`
	InterfaceKind    string         `json:"interface_kind,omitempty"`
	Classifications  []string       `json:"classifications,omitempty"`
	EventID          string         `json:"event_id,omitempty"`
	Attributes       map[string]any `json:"attributes,omitempty"`
}

func (t *ActionTargetSnapshot) UnmarshalJSON(data []byte) error {
	type actionTargetSnapshot ActionTargetSnapshot

	var decoded struct {
		actionTargetSnapshot
		IfAdminStatus json.RawMessage `json:"if_admin_status"`
		IfOperStatus  json.RawMessage `json:"if_oper_status"`
	}

	if err := json.Unmarshal(data, &decoded); err != nil {
		return err
	}

	*t = ActionTargetSnapshot(decoded.actionTargetSnapshot)

	if len(decoded.IfAdminStatus) > 0 {
		status, err := decodeInterfaceStatus(decoded.IfAdminStatus)
		if err != nil {
			return fmt.Errorf("if_admin_status: %w", err)
		}
		t.IfAdminStatus = status
	}

	if len(decoded.IfOperStatus) > 0 {
		status, err := decodeInterfaceStatus(decoded.IfOperStatus)
		if err != nil {
			return fmt.Errorf("if_oper_status: %w", err)
		}
		t.IfOperStatus = status
	}

	return nil
}

func decodeInterfaceStatus(raw json.RawMessage) (string, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return "", err
	}

	switch typed := value.(type) {
	case nil:
		return "", nil
	case string:
		return normalizeInterfaceStatus(typed), nil
	case json.Number:
		return normalizeInterfaceStatus(typed.String()), nil
	default:
		return "", fmt.Errorf("expected string, number, or null, got %T", value)
	}
}

func normalizeInterfaceStatus(value string) string {
	trimmed := strings.TrimSpace(value)

	switch strings.ToLower(trimmed) {
	case "1":
		return "up"
	case "2":
		return "down"
	case "3":
		return "testing"
	default:
		return trimmed
	}
}

func (t ActionTargetSnapshot) Address() string {
	if t.IP != "" {
		return t.IP
	}
	return t.DeviceIP
}

// ActionHostConfig is the merged plugin config supplied to a northbound action plugin.
type ActionHostConfig struct {
	ActionInvocation ActionInvocation `json:"action_invocation"`
	PluginConfig     map[string]any   `json:"-"`
}

func LoadActionConfig() (*ActionHostConfig, error) {
	data, err := getConfigBytes()
	if err != nil {
		return nil, err
	}
	return ParseActionConfig(data)
}

func ParseActionConfig(data []byte) (*ActionHostConfig, error) {
	if len(data) == 0 {
		return nil, errors.New("action config is empty")
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}

	invocationData, ok := raw["action_invocation"]
	if !ok {
		return nil, errors.New("action_invocation is required")
	}

	invocationBytes, err := json.Marshal(invocationData)
	if err != nil {
		return nil, err
	}

	var invocation ActionInvocation
	if err := json.Unmarshal(invocationBytes, &invocation); err != nil {
		return nil, err
	}

	delete(raw, "action_invocation")

	return &ActionHostConfig{ActionInvocation: invocation, PluginConfig: raw}, nil
}

func (c *ActionHostConfig) DecodePluginConfig(out any) error {
	if c == nil {
		return errors.New("action host config is nil")
	}

	data, err := json.Marshal(c.PluginConfig)
	if err != nil {
		return err
	}

	return json.Unmarshal(data, out)
}

type ActionResult struct {
	SchemaVersion         string               `json:"schema"`
	Status                ActionStatus         `json:"status"`
	Summary               map[string]any       `json:"summary,omitempty"`
	ExternalCorrelationID string               `json:"external_correlation_id,omitempty"`
	ContinuationState     map[string]any       `json:"continuation_state,omitempty"`
	PollMode              ActionPollMode       `json:"poll_mode,omitempty"`
	NextPollAt            string               `json:"next_poll_at,omitempty"`
	NextPollDelaySeconds  int                  `json:"next_poll_delay_seconds,omitempty"`
	PollDeadlineAt        string               `json:"poll_deadline_at,omitempty"`
	MaxDurationSeconds    int                  `json:"max_duration_seconds,omitempty"`
	Targets               []ActionTargetResult `json:"targets,omitempty"`
	ErrorClass            string               `json:"error_class,omitempty"`
	ErrorMessage          string               `json:"error_message,omitempty"`
	Metadata              map[string]any       `json:"metadata,omitempty"`
}

type ActionTargetResult struct {
	DeviceUID             string         `json:"device_uid,omitempty"`
	InterfaceUID          string         `json:"interface_uid,omitempty"`
	Status                ActionStatus   `json:"status"`
	Result                map[string]any `json:"result,omitempty"`
	ExternalCorrelationID string         `json:"external_correlation_id,omitempty"`
	ContinuationState     map[string]any `json:"continuation_state,omitempty"`
	PollMode              ActionPollMode `json:"poll_mode,omitempty"`
	NextPollAt            string         `json:"next_poll_at,omitempty"`
	NextPollDelaySeconds  int            `json:"next_poll_delay_seconds,omitempty"`
	PollDeadlineAt        string         `json:"poll_deadline_at,omitempty"`
	MaxDurationSeconds    int            `json:"max_duration_seconds,omitempty"`
}

func NewActionResult(status ActionStatus) *ActionResult {
	return &ActionResult{SchemaVersion: ActionResultSchemaV1, Status: status}
}

func ActionSucceeded(message string) *ActionResult {
	return NewActionResult(ActionStatusSucceeded).WithSummary("message", message)
}

func ActionFailed(class, message string) *ActionResult {
	return NewActionResult(ActionStatusFailed).WithError(class, message)
}

func ActionDeferred(message string) *ActionResult {
	return NewActionResult(ActionStatusDeferred).WithSummary("message", message)
}

func ActionPolling(message string) *ActionResult {
	return NewActionResult(ActionStatusPolling).WithSummary("message", message)
}

func ActionResultFetching(message string) *ActionResult {
	return NewActionResult(ActionStatusFetching).WithSummary("message", message)
}

func (r *ActionResult) WithSummary(key string, value any) *ActionResult {
	if key == "" {
		return r
	}
	if r.Summary == nil {
		r.Summary = make(map[string]any)
	}
	r.Summary[key] = value
	return r
}

func (r *ActionResult) WithCorrelationID(id string) *ActionResult {
	r.ExternalCorrelationID = id
	return r
}

func (r *ActionResult) WithContinuationState(state map[string]any) *ActionResult {
	r.ContinuationState = state
	return r
}

func (r *ActionResult) WithPollMode(mode ActionPollMode) *ActionResult {
	r.PollMode = mode
	return r
}

func (r *ActionResult) WithWebhookCallback() *ActionResult {
	return r.WithPollMode(ActionPollModeWebhook)
}

func (r *ActionResult) WithNextPollDelay(seconds int) *ActionResult {
	r.NextPollDelaySeconds = seconds
	return r
}

func (r *ActionResult) WithNextPollAt(timestamp string) *ActionResult {
	r.NextPollAt = timestamp
	return r
}

func (r *ActionResult) WithPollDeadlineAt(timestamp string) *ActionResult {
	r.PollDeadlineAt = timestamp
	return r
}

func (r *ActionResult) WithMaxDuration(seconds int) *ActionResult {
	r.MaxDurationSeconds = seconds
	return r
}

func (r *ActionResult) WithError(class, message string) *ActionResult {
	r.ErrorClass = class
	r.ErrorMessage = message
	return r
}

func (r *ActionResult) AddTargetResult(result ActionTargetResult) {
	r.Targets = append(r.Targets, result)
}

func (r *ActionResult) WithTargetResult(result ActionTargetResult) *ActionResult {
	r.AddTargetResult(result)
	return r
}

func (r *ActionResult) Serialize() ([]byte, error) {
	if r.SchemaVersion == "" {
		r.SchemaVersion = ActionResultSchemaV1
	}
	if r.Status == "" {
		r.Status = ActionStatusSucceeded
	}
	return json.Marshal(r)
}

func SubmitActionResult(result *ActionResult) error {
	if result == nil {
		result = ActionSucceeded("completed")
	}
	payload, err := result.Serialize()
	if err != nil {
		return err
	}
	return SubmitResult(payload)
}
