import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

/**
 * Creating a sidebar enables you to:
 - create an ordered group of docs
 - render a sidebar for each doc of that group
 - provide next/previous navigation

 The sidebars can be generated from the filesystem, or explicitly defined here.

 Create as many sidebars as you want.
 */
const sidebars: SidebarsConfig = {
  tutorialSidebar: [
    {
      type: 'category',
      label: 'Start Here',
      items: [{type: 'doc', id: 'intro', label: 'Introduction'}, {type: 'doc', id: 'quickstart', label: 'Quickstart'}, {type: 'doc', id: 'architecture', label: 'Architecture'}, {type: 'doc', id: 'repository-layout', label: 'Repository Layout'}],
    },
    {
      type: 'category',
      label: 'Deploy',
      items: [
        {type: 'doc', id: 'docker-setup', label: 'Docker Compose'},
        {type: 'doc', id: 'helm-configuration', label: 'Kubernetes (Helm)'},
        {type: 'doc', id: 'kubernetes-ingestion', label: 'Kubernetes Ingestion'},
        {type: 'doc', id: 'service-port-map', label: 'Service Port Map'},
        {type: 'doc', id: 'tls-security', label: 'TLS / mTLS'},
        {type: 'doc', id: 'self-signed', label: 'Self-Signed Certificates'},
        {type: 'doc', id: 'auth-configuration', label: 'Authentication'},
      ],
    },
    {
      type: 'category',
      label: 'Edge',
      items: [
        {type: 'doc', id: 'edge-model', label: 'Edge Model'},
        {type: 'doc', id: 'edge-agent-onboarding', label: 'Edge Onboarding'},
        {type: 'doc', id: 'agent-release-management', label: 'Agent Release Management'},
        {type: 'doc', id: 'falco', label: 'Falco'},
        {type: 'doc', id: 'falco-integration', label: 'Falco Integration'},
        {type: 'doc', id: 'trivy-integration', label: 'Trivy Integration'},
        {type: 'doc', id: 'armis', label: 'Armis Integration'},
        {type: 'doc', id: 'netbox', label: 'NetBox Integration'},
        {type: 'doc', id: 'wasm-plugins', label: 'Wasm Plugins'},
        {type: 'doc', id: 'ansible', label: 'Ansible Integration'},
        {type: 'doc', id: 'remote-access', label: 'Remote Access'},
        {type: 'doc', id: 'remote-access-rdp', label: 'Remote Access: RDP'},
        {type: 'doc', id: 'proxmox', label: 'Proxmox VE'},
        {type: 'doc', id: 'discovery', label: 'Discovery'},
        {type: 'doc', id: 'network-sweeps', label: 'Network Sweeps'},
        {type: 'doc', id: 'syn-scanner-tuning', label: 'SYN Scanner Tuning'},
        {type: 'doc', id: 'sysmon-profiles', label: 'Sysmon Profiles'},
      ],
    },
    {
      type: 'category',
      label: 'Data',
      items: [
        {type: 'doc', id: 'data-pipeline', label: 'Data Pipeline'},
        {type: 'doc', id: 'device-configuration', label: 'Device Configuration'},
        {type: 'doc', id: 'syslog', label: 'Syslog'},
        {type: 'doc', id: 'snmp', label: 'SNMP'},
        {type: 'doc', id: 'netflow', label: 'NetFlow'},
        {type: 'doc', id: 'bgp-routing', label: 'BGP Routing'},
        {type: 'doc', id: 'otel', label: 'OTEL'},
        {type: 'doc', id: 'rule-builder', label: 'Rule Builder'},
        {type: 'doc', id: 'srql-language-reference', label: 'SRQL Reference'},
        {type: 'doc', id: 'god-view-topology', label: 'God-View Topology'},
        {type: 'doc', id: 'wifi-map-local-compose', label: 'WiFi Map Local Compose'},
      ],
    },
    {
      type: 'category',
      label: 'Extend',
      items: [
        {type: 'doc', id: 'dashboard-sdk', label: 'Dashboard SDK'},
        {type: 'doc', id: 'camera-analysis-reference-worker', label: 'Camera Analysis Worker'},
        {type: 'doc', id: 'fieldsurvey-sidekick', label: 'FieldSurvey Sidekick'},
      ],
    },
    {
      type: 'category',
      label: 'Operations',
      items: [
        {type: 'doc', id: 'tools', label: 'Tools Pod'},
        {type: 'doc', id: 'cnpg-monitoring', label: 'CNPG Monitoring'},
        {type: 'doc', id: 'cnpg-pg18-upgrade-and-search-policy', label: 'CNPG PG18 Upgrade'},
        {type: 'doc', id: 'database-bootstrap', label: 'Database Bootstrap'},
        {type: 'doc', id: 'observability-rollup-recovery', label: 'Observability Rollup Recovery'},
        {type: 'doc', id: 'object-store-retention', label: 'Object Store Retention'},
        {type: 'doc', id: 'mtr-automation-rollout', label: 'MTR Automation Rollout'},
        {type: 'doc', id: 'rust-bazel-deps', label: 'Rust Bazel Dependencies'},
        {type: 'doc', id: 'sync', label: 'Sync Runtime'},
        {type: 'doc', id: 'topology-reset-rebuild', label: 'Topology Reset/Rebuild'},
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting'},
      ],
    },
  ],
};

export default sidebars;
