package terraformprovider

type fieldKind int

const (
	stringField fieldKind = iota
	boolField
	intField
	portsField
)

type field struct {
	name        string
	apiName     string
	kind        fieldKind
	required    bool
	computed    bool
	immutable   bool
	description string
}

type resourceDefinition struct {
	name, route, description string
	fields                   []field
	credential               bool
}

func resourceDefinitions() []resourceDefinition {
	return []resourceDefinition{
		{name: "network_credential_secret", route: "network-credential-secrets", credential: true,
			description: "Reusable encrypted credential. Material is accepted only by values_wo and is never stored in Terraform state. Requires Terraform 1.11 or later.",
			fields: []field{
				{name: "name", required: true}, {name: "description"},
				{name: "credential_provider", apiName: "provider", required: true, immutable: true}, {name: "auth_method", required: true, immutable: true},
				{name: "credential_kind", computed: true}, {name: "username", computed: true},
				{name: "public_fingerprint", computed: true}, {name: "rotation_state", computed: true},
				{name: "last_rotated_at", computed: true},
			}},
		{name: "network_credential_rule", route: "network-credential-rules",
			description: "Scope a unified credential to a provider, purpose, target query, and execution edge.",
			fields: []field{
				{name: "name", required: true}, {name: "description"},
				{name: "credential_provider", apiName: "provider", required: true}, {name: "auth_method", required: true},
				{name: "purpose", required: true}, {name: "target_query", required: true},
				{name: "scope_type", required: true}, {name: "scope_value", required: true},
				{name: "secret_id", required: true}, {name: "allowed_ports", kind: portsField},
				{name: "tls_policy"}, {name: "ssh_host_key_policy"},
				{name: "ca_bundle_pem"}, {name: "server_cert_fingerprint"},
				{name: "priority", kind: intField}, {name: "enabled", kind: boolField},
			}},
		{name: "ansible_controller", route: "ansible-controllers",
			description: "Register an AWX/AAP controller using existing unified credential references. Does not provision upstream AWX objects or launch jobs.",
			fields: []field{
				{name: "name", required: true}, {name: "description"},
				{name: "base_url", required: true}, {name: "agent_id", required: true},
				{name: "sync_credential_secret_id", required: true},
				{name: "execution_credential_secret_id"}, {name: "callback_credential_secret_id"},
				{name: "inventory_sync_interval_seconds", kind: intField}, {name: "catalog_sync_interval_seconds", kind: intField},
				{name: "enabled", kind: boolField}, {name: "status", computed: true}, {name: "awx_version", computed: true},
			}},
		{name: "ansible_repository", route: "ansible-repositories",
			description: "Manage a public Git playbook catalog repository. Server-side catalog synchronization is asynchronous; configuration does not launch playbooks.",
			fields: []field{
				{name: "name", required: true}, {name: "description"}, {name: "git_url", required: true},
				{name: "git_ref"}, {name: "sync_interval_seconds", kind: intField},
				{name: "last_sync_status", computed: true}, {name: "last_sync_at", computed: true},
			}},
	}
}
