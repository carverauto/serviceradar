package sdk

const (
	TargetKindDevice  = "device"
	TargetKindService = "service"

	ResultSchemaTargetCheckV1 = "serviceradar.target_check_result.v1"
)

// CheckDescriptor declares a target-aware check capability exposed by a plugin.
type CheckDescriptor struct {
	DescriptorID           string         `json:"descriptor_id"`
	Version                string         `json:"version"`
	Label                  string         `json:"label"`
	Description            string         `json:"description,omitempty"`
	TargetKinds            []string       `json:"target_kinds"`
	ServiceKinds           []string       `json:"service_kinds,omitempty"`
	Protocols              []string       `json:"protocols,omitempty"`
	RequiredTargetFields   []string       `json:"required_target_fields,omitempty"`
	OptionalTargetFields   []string       `json:"optional_target_fields,omitempty"`
	RequiredCapabilities   []string       `json:"required_capabilities,omitempty"`
	CredentialRequirements map[string]any `json:"credential_requirements,omitempty"`
	ScheduleBounds         map[string]any `json:"schedule_bounds,omitempty"`
	TimeoutBounds          map[string]any `json:"timeout_bounds,omitempty"`
	ThresholdSchema        map[string]any `json:"threshold_schema,omitempty"`
	AllowlistPolicy        map[string]any `json:"allowlist_policy,omitempty"`
	DisplayContractRef     string         `json:"display_contract_ref,omitempty"`
	ResultSchemaVersion    string         `json:"result_schema_version"`
}

// NewCheckDescriptor returns a descriptor with target-scoped result defaults.
func NewCheckDescriptor(descriptorID, version, label string) CheckDescriptor {
	return CheckDescriptor{
		DescriptorID:        descriptorID,
		Version:             version,
		Label:               label,
		ResultSchemaVersion: ResultSchemaTargetCheckV1,
	}
}

func (d CheckDescriptor) WithDescription(description string) CheckDescriptor {
	d.Description = description
	return d
}

func (d CheckDescriptor) WithTargetKinds(kinds ...string) CheckDescriptor {
	d.TargetKinds = append([]string(nil), kinds...)
	return d
}

func (d CheckDescriptor) WithServiceKinds(kinds ...string) CheckDescriptor {
	d.ServiceKinds = append([]string(nil), kinds...)
	return d
}

func (d CheckDescriptor) WithProtocols(protocols ...string) CheckDescriptor {
	d.Protocols = append([]string(nil), protocols...)
	return d
}

func (d CheckDescriptor) WithRequiredTargetFields(fields ...string) CheckDescriptor {
	d.RequiredTargetFields = append([]string(nil), fields...)
	return d
}

func (d CheckDescriptor) WithOptionalTargetFields(fields ...string) CheckDescriptor {
	d.OptionalTargetFields = append([]string(nil), fields...)
	return d
}

func (d CheckDescriptor) WithRequiredCapabilities(capabilities ...string) CheckDescriptor {
	d.RequiredCapabilities = append([]string(nil), capabilities...)
	return d
}

func (d CheckDescriptor) WithCredentialRequirements(requirements map[string]any) CheckDescriptor {
	d.CredentialRequirements = cloneMap(requirements)
	return d
}

func (d CheckDescriptor) WithScheduleBounds(bounds map[string]any) CheckDescriptor {
	d.ScheduleBounds = cloneMap(bounds)
	return d
}

func (d CheckDescriptor) WithTimeoutBounds(bounds map[string]any) CheckDescriptor {
	d.TimeoutBounds = cloneMap(bounds)
	return d
}

func (d CheckDescriptor) WithThresholdSchema(schema map[string]any) CheckDescriptor {
	d.ThresholdSchema = cloneMap(schema)
	return d
}

func (d CheckDescriptor) WithAllowlistPolicy(policy map[string]any) CheckDescriptor {
	d.AllowlistPolicy = cloneMap(policy)
	return d
}

func cloneMap(in map[string]any) map[string]any {
	if len(in) == 0 {
		return nil
	}

	out := make(map[string]any, len(in))
	for key, value := range in {
		out[key] = value
	}
	return out
}
