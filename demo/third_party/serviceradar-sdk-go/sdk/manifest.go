package sdk

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Manifest validation mirrors ServiceRadar.Plugins.Manifest in
// elixir/serviceradar_core/lib/serviceradar/plugins/manifest.ex. Core validates
// every uploaded plugin.yaml against strict allowlists and rejects unknown keys
// outright, so a manifest that fails Validate here would also be rejected at
// upload. Keeping the two in sync is the point: plugin authors should learn
// about a bad manifest at build time, not from a package upload error.
const (
	RuntimeNone         = "none"
	RuntimeWASIPreview1 = "wasi-preview1"

	OutputsPluginResult   = "serviceradar.plugin_result.v1"
	OutputsCameraStream   = "serviceradar.camera_stream.v1"
	OutputsProxmoxConsole = "serviceradar.proxmox_console.v1"
)

// allowedRuntimes mirrors @allowed_runtimes.
var allowedRuntimes = []string{RuntimeNone, RuntimeWASIPreview1}

// allowedOutputs mirrors @allowed_outputs.
var allowedOutputs = []string{OutputsPluginResult, OutputsCameraStream, OutputsProxmoxConsole}

// allowedCapabilities mirrors @allowed_capabilities.
var allowedCapabilities = []string{
	"get_config",
	"log",
	"submit_result",
	"emit_telemetry",
	"http_request",
	"websocket_connect",
	"websocket_send",
	"websocket_recv",
	"websocket_close",
	"camera_media_stream",
	"proxmox_console_stream",
	"tcp_connect",
	"tcp_read",
	"tcp_write",
	"tcp_close",
	"udp_sendto",
	"artifact-staging:v1",
	"advisory-feed:v1",
	"producer-schedule:v1",
	"action-result-ingest:v1",
	"action-only:v1",
}

// Limits mirror @max_signal_ref_length and @max_signal_path_length.
const (
	maxSignalRefLength  = 160
	maxSignalPathLength = 240
)

// The rules below are hand-written rather than compiled regexps on purpose.
// This package is linked into every TinyGo plugin, so a package-level
// regexp.MustCompile would pull the regexp engine into plugins that never build
// a manifest and run at startup for all of them. The Rust SDK does the same.

// PluginManifest is the plugin.yaml shape accepted by ServiceRadar core.
//
// Field order and JSON keys match core's manifest reader. Core rejects unknown
// keys, so this struct deliberately carries no fields beyond the documented
// contract.
type PluginManifest struct {
	ID            string                     `json:"id"`
	Name          string                     `json:"name"`
	Version       string                     `json:"version"`
	Description   string                     `json:"description,omitempty"`
	Entrypoint    string                     `json:"entrypoint"`
	Runtime       string                     `json:"runtime,omitempty"`
	Capabilities  []string                   `json:"capabilities"`
	Permissions   map[string]any             `json:"permissions,omitempty"`
	Resources     map[string]any             `json:"resources"`
	Outputs       string                     `json:"outputs"`
	SignalSchemas []SignalSchemaContribution `json:"signal_schemas,omitempty"`
}

// SignalSchemaContribution declares a package-owned signal schema and display
// contract shipped inside the plugin bundle. Add-ons that emit logs or events
// are required to declare one.
//
// The field set is closed: core validates signal_schemas entries against an
// explicit key allowlist and reports "signal_schemas[i].<key> is not allowed"
// for anything else.
type SignalSchemaContribution struct {
	ID                     string `json:"id"`
	Version                string `json:"version"`
	SignalType             string `json:"signal_type"`
	PayloadKind            string `json:"payload_kind"`
	PayloadSchema          string `json:"payload_schema"`
	DisplayContract        string `json:"display_contract"`
	DisplayContractID      string `json:"display_contract_id"`
	DisplayContractVersion string `json:"display_contract_version"`
	OCSFSchemaVersion      string `json:"ocsf_schema_version,omitempty"`
	ClassUID               int    `json:"class_uid,omitempty"`
	TypeUID                int    `json:"type_uid,omitempty"`
}

// NewSignalSchemaContribution builds a contribution with conventional bundle
// paths derived from the schema id. Callers may override any field afterwards.
func NewSignalSchemaContribution(id, version, signalType, payloadKind string) SignalSchemaContribution {
	short := shortSchemaName(id)

	return SignalSchemaContribution{
		ID:                     id,
		Version:                version,
		SignalType:             signalType,
		PayloadKind:            payloadKind,
		PayloadSchema:          "schemas/" + short + ".schema.json",
		DisplayContract:        "display/" + short + ".display.json",
		DisplayContractID:      id + ".display",
		DisplayContractVersion: version,
	}
}

// WithOCSF sets the OCSF classification fields on a contribution.
func (s SignalSchemaContribution) WithOCSF(schemaVersion string, classUID, typeUID int) SignalSchemaContribution {
	s.OCSFSchemaVersion = schemaVersion
	s.ClassUID = classUID
	s.TypeUID = typeUID

	return s
}

// Serialize validates the manifest and returns its JSON encoding.
func (m PluginManifest) Serialize() ([]byte, error) {
	if err := m.Validate(); err != nil {
		return nil, err
	}

	return json.Marshal(m)
}

// Validate reports every way the manifest would be rejected by core, joined
// into a single error so authors can fix them in one pass.
func (m PluginManifest) Validate() error {
	var errs []string

	for _, field := range []struct {
		name  string
		value string
	}{
		{"id", m.ID},
		{"name", m.Name},
		{"version", m.Version},
		{"entrypoint", m.Entrypoint},
	} {
		if strings.TrimSpace(field.value) == "" {
			errs = append(errs, field.name+" must be set")
		}
	}

	if m.Runtime != "" && !isAllowedValue(allowedRuntimes, m.Runtime) {
		errs = append(errs, "runtime must be one of: "+strings.Join(allowedRuntimes, ", "))
	}

	if !isAllowedValue(allowedOutputs, m.Outputs) {
		errs = append(errs, "outputs must be one of: "+strings.Join(allowedOutputs, ", "))
	}

	if len(m.Capabilities) == 0 {
		errs = append(errs, "capabilities must be set")
	}

	for _, capability := range m.Capabilities {
		if !isAllowedValue(allowedCapabilities, capability) {
			errs = append(errs, "capabilities contains unsupported capability "+capability)
		}
	}

	if len(m.Resources) == 0 {
		errs = append(errs, "resources must be set")
	}

	for i, schema := range m.SignalSchemas {
		errs = append(errs, schema.validate(fmt.Sprintf("signal_schemas[%d]", i))...)
	}

	if len(errs) > 0 {
		return fmt.Errorf("invalid plugin manifest: %s", strings.Join(errs, "; "))
	}

	return nil
}

func (s SignalSchemaContribution) validate(path string) []string {
	var errs []string

	errs = append(errs, validateSignalRef(s.ID, path+".id")...)
	errs = append(errs, validateSignalRef(s.DisplayContractID, path+".display_contract_id")...)
	errs = append(errs, validateSemver(s.Version, path+".version")...)
	errs = append(errs, validateSemver(s.DisplayContractVersion, path+".display_contract_version")...)

	if s.OCSFSchemaVersion != "" {
		errs = append(errs, validateSemver(s.OCSFSchemaVersion, path+".ocsf_schema_version")...)
	}

	if s.SignalType != SignalSchemaSignalTypeEvent && s.SignalType != SignalSchemaSignalTypeLog {
		errs = append(errs, path+".signal_type must be one of: "+
			SignalSchemaSignalTypeEvent+", "+SignalSchemaSignalTypeLog)
	}

	if s.PayloadKind != SignalSchemaPayloadKindOCSFEvent && s.PayloadKind != SignalSchemaPayloadKindOTELLog {
		errs = append(errs, path+".payload_kind must be one of: "+
			SignalSchemaPayloadKindOCSFEvent+", "+SignalSchemaPayloadKindOTELLog)
	}

	errs = append(errs, validateBundlePath(s.PayloadSchema, path+".payload_schema")...)
	errs = append(errs, validateBundlePath(s.DisplayContract, path+".display_contract")...)

	if s.ClassUID < 0 {
		errs = append(errs, path+".class_uid must be a positive integer")
	}

	if s.TypeUID < 0 {
		errs = append(errs, path+".type_uid must be a positive integer")
	}

	return errs
}

func validateSignalRef(value, path string) []string {
	switch {
	case strings.TrimSpace(value) == "":
		return []string{path + " must be a non-empty string"}
	case len(value) > maxSignalRefLength:
		return []string{path + " exceeds maximum length"}
	case !isSignalRef(value):
		return []string{path + " must use lowercase letters, numbers, dots, underscores, or hyphens"}
	default:
		return nil
	}
}

// isSignalRef mirrors core's lowercase reverse-DNS identifier rule.
func isSignalRef(value string) bool {
	for i, c := range value {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case (c == '_' || c == '.' || c == '-') && i > 0:
		default:
			return false
		}
	}

	return value != ""
}

func validateSemver(value, path string) []string {
	if !isSemver(value) {
		return []string{path + " must be a valid semver string"}
	}

	return nil
}

// isSemver mirrors core's semver rule for schema versions:
// three dot-separated numeric parts, with an optional -/+ suffix of
// alphanumerics, dots, and hyphens.
func isSemver(value string) bool {
	core := value

	if i := strings.IndexAny(value, "-+"); i >= 0 {
		core = value[:i]
		suffix := value[i+1:]

		if suffix == "" {
			return false
		}

		for _, c := range suffix {
			if !isASCIIAlphanumeric(c) && c != '.' && c != '-' {
				return false
			}
		}
	}

	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return false
	}

	for _, part := range parts {
		if part == "" {
			return false
		}

		for _, c := range part {
			if c < '0' || c > '9' {
				return false
			}
		}
	}

	return true
}

func validateBundlePath(value, path string) []string {
	switch {
	case strings.TrimSpace(value) == "":
		return []string{path + " must be a non-empty string"}
	case len(value) > maxSignalPathLength:
		return []string{path + " exceeds maximum length"}
	case strings.Contains(value, ".."):
		return []string{path + " must not traverse directories"}
	case !strings.HasSuffix(value, ".json"):
		return []string{path + " must reference a JSON file"}
	case !isRelativeBundlePath(value):
		return []string{path + " must be a relative bundle path"}
	default:
		return nil
	}
}

// isRelativeBundlePath mirrors core's relative-bundle-path rule: slash-separated
// segments of alphanumerics, underscores, dots, and hyphens, each starting with
// an alphanumeric, underscore, or hyphen.
func isRelativeBundlePath(value string) bool {
	if strings.HasPrefix(value, "/") || strings.HasSuffix(value, "/") {
		return false
	}

	for _, segment := range strings.Split(value, "/") {
		if segment == "" {
			return false
		}

		for i, c := range segment {
			switch {
			case isASCIIAlphanumeric(c), c == '_', c == '-':
			case c == '.' && i > 0:
			default:
				return false
			}
		}
	}

	return true
}

func isASCIIAlphanumeric(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

func isAllowedValue(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}

	return false
}

func shortSchemaName(id string) string {
	parts := strings.Split(id, ".")

	return parts[len(parts)-1]
}
