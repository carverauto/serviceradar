package config

import (
	"fmt"
	"sort"
	"strings"
)

var (
	errNoKVKeyDefined         = fmt.Errorf("descriptor does not define a KV key")
	errAgentIDRequired        = fmt.Errorf("descriptor requires agent_id")
	errGatewayIDRequired      = fmt.Errorf("descriptor requires gateway_id")
	errUnresolvedTemplateVars = fmt.Errorf("descriptor has unresolved template variables")
)

const templatePrefix = "templates"

// ConfigFormat identifies how a service persists its configuration.
type ConfigFormat string

const (
	ConfigFormatJSON ConfigFormat = "json"
	ConfigFormatTOML ConfigFormat = "toml"
)

// ConfigScope describes how a service scopes its configuration.
type ConfigScope string

const (
	ConfigScopeGlobal  ConfigScope = "global"
	ConfigScopeGateway ConfigScope = "gateway"
	ConfigScopeAgent   ConfigScope = "agent"
)

// ServiceDescriptor captures metadata about a managed service configuration.
type ServiceDescriptor struct {
	Name           string
	DisplayName    string
	ServiceType    string
	Scope          ConfigScope
	KVKey          string
	KVKeyTemplate  string
	Format         ConfigFormat
	CriticalFields []string
}

// KeyContext supplies identity information used to resolve scoped KV keys.
type KeyContext struct {
	AgentID   string
	GatewayID string
}

// serviceDescriptorTable lists every known service's descriptor.
func serviceDescriptorTable() []ServiceDescriptor {
	return []ServiceDescriptor{
		{
			Name:        "core",
			DisplayName: "Core Service",
			ServiceType: "core",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/core.json",
			Format:      ConfigFormatJSON,
			CriticalFields: []string{
				"edge_onboarding.encryption_key",
				"auth.jwt_public_key_pem",
			},
		},
		{
			Name:          "gateway",
			DisplayName:   "Gateway",
			ServiceType:   "gateway",
			Scope:         ConfigScopeGateway,
			KVKeyTemplate: "config/gateways/{{gateway_id}}.json",
			Format:        ConfigFormatJSON,
			CriticalFields: []string{
				"kv_address",
				"core_address",
			},
		},
		{
			Name:          "agent",
			DisplayName:   "Agent Defaults",
			ServiceType:   "agent",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "config/agents/{{agent_id}}.json",
			Format:        ConfigFormatJSON,
			CriticalFields: []string{
				"kv_address",
			},
		},
		{
			Name:        "flowgger",
			DisplayName: "Flowgger Collector",
			ServiceType: "flowgger",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/flowgger.toml",
			Format:      ConfigFormatTOML,
		},
		{
			Name:        "otel",
			DisplayName: "OTel Collector",
			ServiceType: "otel",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/otel.toml",
			Format:      ConfigFormatTOML,
		},
		{
			Name:        "trapd",
			DisplayName: "Trap Daemon",
			ServiceType: "trapd",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/trapd.json",
			Format:      ConfigFormatJSON,
		},
		{
			Name:        "datasvc",
			DisplayName: "Data Service",
			ServiceType: "datasvc",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/datasvc.json",
			Format:      ConfigFormatJSON,
			CriticalFields: []string{
				"kv_address",
			},
		},
		{
			Name:        "sysmon-osx-checker",
			DisplayName: "Sysmon-OSX Checker",
			ServiceType: "sysmon-osx-checker",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/sysmon-osx-checker.json",
			Format:      ConfigFormatJSON,
		},
		{
			Name:        "sysmon-checker",
			DisplayName: "Sysmon Checker",
			ServiceType: "sysmon-checker",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/sysmon-checker.json",
			Format:      ConfigFormatJSON,
		},
		{
			Name:        "rperf-checker",
			DisplayName: "RPerf Checker",
			ServiceType: "rperf-checker",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/rperf-checker.json",
			Format:      ConfigFormatJSON,
		},
		{
			Name:        "profiler",
			DisplayName: "Profiler Service",
			ServiceType: "profiler",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/profiler.toml",
			Format:      ConfigFormatTOML,
		},
		{
			Name:        "faker",
			DisplayName: "Faker API",
			ServiceType: "faker",
			Scope:       ConfigScopeGlobal,
			KVKey:       "config/faker.json",
			Format:      ConfigFormatJSON,
		},
		{
			Name:          "agent-sweep",
			DisplayName:   "Sweep Checker",
			ServiceType:   "sweep",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "agents/{{agent_id}}/checkers/sweep/sweep.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "agent-snmp",
			DisplayName:   "Agent SNMP Checker",
			ServiceType:   "snmp",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "agents/{{agent_id}}/checkers/snmp/snmp.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "agent-trapd",
			DisplayName:   "Trapd Checker",
			ServiceType:   "trapd",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "agents/{{agent_id}}/checkers/trapd/trapd.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "agent-rperf",
			DisplayName:   "RPerf Checker",
			ServiceType:   "rperf",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "agents/{{agent_id}}/checkers/rperf/rperf.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "agent-sysmon",
			DisplayName:   "Sysmon Checker",
			ServiceType:   "sysmon",
			Scope:         ConfigScopeAgent,
			KVKeyTemplate: "agents/{{agent_id}}/checkers/sysmon/sysmon.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "gateway-icmp",
			DisplayName:   "ICMP Check",
			ServiceType:   "icmp",
			Scope:         ConfigScopeGateway,
			KVKeyTemplate: "config/gateways/{{gateway_id}}.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "gateway-port",
			DisplayName:   "Port Check",
			ServiceType:   "port",
			Scope:         ConfigScopeGateway,
			KVKeyTemplate: "config/gateways/{{gateway_id}}.json",
			Format:        ConfigFormatJSON,
		},
		{
			Name:          "gateway-process",
			DisplayName:   "Process Check",
			ServiceType:   "process",
			Scope:         ConfigScopeGateway,
			KVKeyTemplate: "config/gateways/{{gateway_id}}.json",
			Format:        ConfigFormatJSON,
		},
	}
}

// ServiceDescriptorFor returns the descriptor for a named service if it exists.
func ServiceDescriptorFor(name string) (ServiceDescriptor, bool) {
	for _, desc := range serviceDescriptorTable() {
		if desc.Name == name {
			return desc, true
		}
	}
	return ServiceDescriptor{}, false
}

// ServiceDescriptorByType returns the descriptor matching a service type within the provided scope.
func ServiceDescriptorByType(serviceType string, scope ConfigScope) (ServiceDescriptor, bool) {
	for _, desc := range serviceDescriptorTable() {
		if desc.Scope != scope {
			continue
		}
		if desc.ServiceType == serviceType {
			return desc, true
		}
	}
	return ServiceDescriptor{}, false
}

// ServiceDescriptors returns the known service descriptors in deterministic order.
func ServiceDescriptors() []ServiceDescriptor {
	result := serviceDescriptorTable()
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result
}

// ResolveKVKey returns the KV key for the descriptor within the provided context.
func (sd ServiceDescriptor) ResolveKVKey(ctx KeyContext) (string, error) {
	if sd.KVKeyTemplate == "" {
		if sd.KVKey == "" {
			return "", fmt.Errorf("%w: %s", errNoKVKeyDefined, sd.Name)
		}
		return sd.KVKey, nil
	}

	key := sd.KVKeyTemplate
	if strings.Contains(key, "{{agent_id}}") {
		if ctx.AgentID == "" {
			return "", fmt.Errorf("%w: %s", errAgentIDRequired, sd.Name)
		}
		key = strings.ReplaceAll(key, "{{agent_id}}", ctx.AgentID)
	}
	if strings.Contains(key, "{{gateway_id}}") {
		if ctx.GatewayID == "" {
			return "", fmt.Errorf("%w: %s", errGatewayIDRequired, sd.Name)
		}
		key = strings.ReplaceAll(key, "{{gateway_id}}", ctx.GatewayID)
	}
	if strings.Contains(key, "{{") {
		return "", fmt.Errorf("%w: %s", errUnresolvedTemplateVars, sd.Name)
	}
	return key, nil
}

// TemplateStorageKey returns the canonical KV location for storing a descriptor's default template.
func TemplateStorageKey(desc ServiceDescriptor) string {
	if desc.Name == "" {
		return ""
	}

	extension := "json"
	if desc.Format == ConfigFormatTOML {
		extension = "toml"
	}

	return fmt.Sprintf("%s/%s.%s", templatePrefix, desc.Name, extension)
}

// TemplateStorageKeyFor returns the template storage key for the provided descriptor name, if known.
func TemplateStorageKeyFor(name string) (string, ConfigFormat, bool) {
	desc, ok := ServiceDescriptorFor(name)
	if !ok {
		return "", "", false
	}
	return TemplateStorageKey(desc), desc.Format, true
}
