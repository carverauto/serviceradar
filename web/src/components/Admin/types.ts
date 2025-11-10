export type ConfigScope = 'global' | 'poller' | 'agent';

export interface ConfigDescriptor {
  name: string;
  display_name?: string;
  service_type: string;
  scope: ConfigScope;
  kv_key?: string;
  kv_key_template?: string;
  format: 'json' | 'toml';
  requires_agent?: boolean;
  requires_poller?: boolean;
}
