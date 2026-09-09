import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

/**
 * The ServiceRadar documentation sidebar is organized into task-based sections
 * so new and experienced users can find what they need quickly.
 */
const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    {
      type: 'category',
      label: 'Start Here',
      collapsed: false,
      items: [
        {type: 'doc', id: 'intro', label: 'Introduction'},
        {type: 'doc', id: 'cloud-quickstart', label: 'Cloud Quickstart'},
        {type: 'doc', id: 'quickstart', label: 'Self-hosted Quickstart'},
        {type: 'doc', id: 'architecture', label: 'Architecture'},
        {type: 'doc', id: 'web-ui-overview', label: 'Navigating the Web UI'},
      ],
    },
    {
      type: 'category',
      label: 'Deploy',
      items: [
        {type: 'doc', id: 'cloud-quickstart', label: 'Cloud Quickstart'},
        {type: 'doc', id: 'docker-setup', label: 'Docker Compose'},
        {type: 'doc', id: 'helm-configuration', label: 'Kubernetes (Helm)'},
        {type: 'doc', id: 'declarative-environments', label: 'Declarative Environments'},
        {type: 'doc', id: 'terraform-provider', label: 'Terraform Provider'},
        {type: 'doc', id: 'ansible-provisioning-api', label: 'Ansible Provisioning API'},
        {type: 'doc', id: 'kubernetes-ingestion', label: 'Kubernetes Ingestion'},
        {
          type: 'doc',
          id: 'k8s-public-endpoint-inventory',
          label: 'Public Endpoint Inventory',
        },
        {type: 'doc', id: 'service-ports', label: 'Kubernetes Ingress'},
        {type: 'doc', id: 'service-port-map', label: 'Service Port Map'},
        {
          type: 'doc',
          id: 'tls-security',
          label: 'TLS & mTLS (advanced)',
        },
        {type: 'doc', id: 'auth-configuration', label: 'Authentication'},
        {type: 'doc', id: 'rbac-and-roles', label: 'Roles & Permissions'},
        {type: 'doc', id: 'group-permission-mapping', label: 'Group Permission Mapping'},
      ],
    },
    {
      type: 'category',
      label: 'Edge & Agents',
      items: [
        {type: 'doc', id: 'edge-model', label: 'Edge Model'},
        {type: 'doc', id: 'edge-agent-onboarding', label: 'Edge Onboarding'},
        {type: 'doc', id: 'agent-configuration', label: 'Agent Configuration'},
        {type: 'doc', id: 'agent-release-management', label: 'Agent Release Management'},
        {
          type: 'category',
          label: 'Native Add-ons',
          items: [
            {type: 'doc', id: 'native-addons', label: 'Overview'},
            {type: 'doc', id: 'addon-config-contracts', label: 'Config Contracts'},
            {type: 'doc', id: 'netprobe', label: 'Host Network Visibility'},
            {type: 'doc', id: 'visibility-profiles', label: 'Visibility Profiles'},
            {type: 'doc', id: 'workload-identity', label: 'Workload Identity'},
          ],
        },
        {type: 'doc', id: 'discovery', label: 'Discovery'},
        {type: 'doc', id: 'network-sweeps', label: 'Network Sweeps'},
        {type: 'doc', id: 'sweep-banner-grab', label: 'Sweep Banner Grab'},
        {type: 'doc', id: 'syn-scanner-tuning', label: 'SYN Scanner Tuning'},
        {type: 'doc', id: 'sysmon-profiles', label: 'Sysmon Profiles'},
        {type: 'doc', id: 'visibility-profiles', label: 'Visibility Profiles'},
        {type: 'doc', id: 'fingerprint-architecture', label: 'Fingerprint Architecture'},
        {type: 'doc', id: 'rperf', label: 'Network Performance Testing'},
      ],
    },
    {
      type: 'category',
      label: 'Integrations',
      items: [
        {type: 'doc', id: 'credentials', label: 'Credential Management'},
        {type: 'doc', id: 'sync', label: 'Sync Runtime'},
        {type: 'doc', id: 'armis', label: 'Armis'},
        {type: 'doc', id: 'netbox', label: 'NetBox'},
        {type: 'doc', id: 'prefix-tags', label: 'Prefix Tags'},
        {type: 'doc', id: 'ansible', label: 'Ansible'},
        {type: 'doc', id: 'proxmox', label: 'Proxmox VE'},
        {type: 'doc', id: 'unifi-protect', label: 'UniFi Protect'},
        {type: 'doc', id: 'opentext-nom', label: 'OpenText NOM'},
        {type: 'doc', id: 'remote-access', label: 'Remote Access'},
        {type: 'doc', id: 'remote-access-rdp', label: 'Remote Access: RDP'},
      ],
    },
    {
      type: 'category',
      label: 'Get Data In',
      items: [
        {type: 'doc', id: 'data-pipeline', label: 'Data Pipeline'},
        {type: 'doc', id: 'device-configuration', label: 'Device Configuration'},
        {type: 'doc', id: 'syslog', label: 'Syslog'},
        {type: 'doc', id: 'snmp', label: 'SNMP'},
        {type: 'doc', id: 'netflow', label: 'NetFlow'},
        {type: 'doc', id: 'bgp-routing', label: 'BGP Routing'},
        {type: 'doc', id: 'otel', label: 'OpenTelemetry'},
      ],
    },
    {
      type: 'category',
      label: 'Security',
      items: [
        {type: 'doc', id: 'threat-investigation', label: 'Threat Investigation'},
        {type: 'doc', id: 'endpoint-software-security', label: 'Endpoint Software Security'},
        {type: 'doc', id: 'falco', label: 'Falco Runtime Detection'},
        {type: 'doc', id: 'trivy-integration', label: 'Trivy Vulnerability Reports'},
        {type: 'doc', id: 'bumblebee', label: 'Bumblebee Exposure Scanning'},
      ],
    },
    {
      type: 'category',
      label: 'Query & Analyze',
      items: [
        {type: 'doc', id: 'srql-tutorial', label: 'SRQL Tutorial'},
        {type: 'doc', id: 'srql-language-reference', label: 'SRQL Reference'},
        {type: 'doc', id: 'srql-cookbook', label: 'SRQL Cookbook'},
        {type: 'doc', id: 'mcp-integration', label: 'MCP Integration'},
        {type: 'doc', id: 'self-authored-dashboards', label: 'Self-Authored Dashboards'},
        {type: 'doc', id: 'api-reference', label: 'API Reference'},
        {type: 'doc', id: 'identity-resolve', label: 'Resolve a Device Identity'},
        {type: 'doc', id: 'device-facts', label: 'Device Facts API'},
        {type: 'doc', id: 'validation-runs', label: 'Validation Runs'},
        {type: 'doc', id: 'rule-builder', label: 'Rule Builder'},
        {type: 'doc', id: 'network-topology', label: 'Network Topology'},
      ],
    },
    {
      type: 'category',
      label: 'Extend',
      items: [
        {type: 'doc', id: 'sdks', label: 'SDKs & Plugin Development'},
        {type: 'doc', id: 'wasm-plugins', label: 'Wasm Plugins'},
        {type: 'doc', id: 'telemetry-display-contracts', label: 'Telemetry Display Contracts'},
        {type: 'doc', id: 'dashboard-sdk', label: 'Dashboard SDK'},
        {type: 'doc', id: 'fieldsurvey-sidekick', label: 'FieldSurvey Sidekick'},
      ],
    },
    {
      type: 'category',
      label: 'Operate',
      items: [
        {type: 'doc', id: 'tools', label: 'Tools Pod'},
        {type: 'doc', id: 'cli-reference', label: 'ServiceRadar CLI'},
        {type: 'doc', id: 'configuration-system', label: 'Configuration & KV Store'},
        {type: 'doc', id: 'outbound-mail', label: 'Outbound Mail'},
        {
          type: 'category',
          label: 'Notifications',
          items: [
            {type: 'doc', id: 'notification-quickstart', label: 'Quickstart'},
            {type: 'doc', id: 'notifications', label: 'How Notifications Work'},
            {type: 'doc', id: 'notification-providers', label: 'Declarative Providers'},
            {type: 'doc', id: 'notification-plugin-authoring', label: 'Notification Plugins (Wasm)'},
          ],
        },
        {type: 'doc', id: 'anomaly-engine', label: 'Anomaly Engine'},
        {type: 'doc', id: 'anomaly-detection', label: 'Anomaly Detection (Tuning)'},
        {type: 'doc', id: 'database-bootstrap', label: 'Database Bootstrap'},
        {type: 'doc', id: 'cnpg-monitoring', label: 'CNPG Monitoring'},
        {type: 'doc', id: 'observability-rollup-recovery', label: 'Observability Rollup Recovery'},
        {type: 'doc', id: 'object-store-retention', label: 'Object Store Retention'},
        {type: 'doc', id: 'release-artifact-integrity', label: 'Release Artifact Integrity'},
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting'},
      ],
    },
  ],
};

export default sidebars;
