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
      label: 'Overview',
      items: [
        {type: 'doc', id: 'intro', label: 'Why ServiceRadar'},
        {type: 'doc', id: 'architecture', label: 'Architecture'},
        {type: 'doc', id: 'cluster', label: 'Cluster'},
        {type: 'doc', id: 'quickstart', label: 'Quickstart'},
      ],
    },
    {
      type: 'category',
      label: 'Deploy',
      items: [
        {type: 'doc', id: 'installation', label: 'Installation'},
        {type: 'doc', id: 'docker-setup', label: 'Docker'},
        {type: 'doc', id: 'helm-configuration', label: 'Kubernetes'},
        {type: 'doc', id: 'edge-onboarding', label: 'Edge Onboarding'},
        {type: 'doc', id: 'edge-agent-onboarding', label: 'Edge Agent Onboarding'},
      ],
    },
    {
      type: 'category',
      label: 'Collect & Discover',
      items: [
        {type: 'doc', id: 'edge-agents', label: 'Edge Agents'},
        {type: 'doc', id: 'sync', label: 'Sync Runtime'},
        {type: 'doc', id: 'discovery', label: 'Discovery'},
        {type: 'doc', id: 'network-sweeps', label: 'Network Sweeps'},
        {type: 'doc', id: 'snmp', label: 'SNMP'},
        {type: 'doc', id: 'syslog', label: 'Syslog'},
        {type: 'doc', id: 'netflow', label: 'NetFlow'},
        {type: 'doc', id: 'otel', label: 'OTEL'},
        {type: 'doc', id: 'device-configuration', label: 'Device Configuration Reference'},
        {type: 'doc', id: 'sysmon-profiles', label: 'Sysmon Profiles'},
        {type: 'doc', id: 'sysmon-local-config', label: 'Sysmon Local Config'},
      ],
    },
    {
      type: 'category',
      label: 'Integrations',
      items: [
        {type: 'doc', id: 'armis', label: 'Armis'},
        {type: 'doc', id: 'netbox', label: 'NetBox'},
        {type: 'doc', id: 'rperf-monitoring', label: 'rperf Monitoring'},
      ],
    },
    {
      type: 'category',
      label: 'Configure',
      items: [
        {type: 'doc', id: 'configuration', label: 'Configuration'},
        {type: 'doc', id: 'kv-configuration', label: 'KV Configuration'},
        {type: 'doc', id: 'service-port-map', label: 'Service Port Map'},
        {type: 'doc', id: 'custom-checkers', label: 'Custom Checkers'},
        {type: 'doc', id: 'web-ui', label: 'Web UI'},
        {type: 'doc', id: 'rule-builder', label: 'Rule Builder'},
      ],
    },
    {
      type: 'category',
      label: 'Security',
      items: [
        {type: 'doc', id: 'tls-security', label: 'TLS Security'},
        {type: 'doc', id: 'spiffe-identity', label: 'SPIFFE / SPIRE'},
        {type: 'doc', id: 'security-architecture', label: 'Security Architecture'},
        {type: 'doc', id: 'auth-configuration', label: 'Authentication'},
        {type: 'doc', id: 'self-signed', label: 'Self-Signed Certs'},
      ],
    },
    {
      type: 'category',
      label: 'Operations',
      items: [
        {type: 'doc', id: 'agents', label: 'Agents & Demo Operations'},
        {type: 'doc', id: 'search-planner-operations', label: 'Search Planner Ops'},
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting Guide'},
        {type: 'doc', id: 'identity-metrics', label: 'Identity Metrics'},
        {type: 'doc', id: 'identity-alerts', label: 'Identity Alerts'},
        {type: 'doc', id: 'identity_drift_monitoring', label: 'Identity Drift Monitoring'},
      ],
    },
    {
      type: 'category',
      label: 'Query & Data',
      items: [
        {type: 'doc', id: 'srql-language-reference', label: 'SRQL Language Reference'},
        {type: 'doc', id: 'srql-service', label: 'SRQL Service'},
        {type: 'doc', id: 'ocsf-device-schema', label: 'OCSF Device Schema'},
        {type: 'doc', id: 'age-graph-schema', label: 'AGE Graph Schema'},
        {type: 'doc', id: 'cnpg-monitoring', label: 'CNPG Monitoring'},
      ],
    },
    {
      type: 'category',
      label: 'Platform Internals',
      items: [
        {type: 'doc', id: 'ash-api', label: 'Ash API'},
        {type: 'doc', id: 'ash-authentication', label: 'Ash Authentication'},
        {type: 'doc', id: 'ash-authorization', label: 'Ash Authorization'},
        {type: 'doc', id: 'ash-domains', label: 'Ash Domains'},
        {type: 'doc', id: 'ash-migration-guide', label: 'Ash Migration Guide'},
        {type: 'doc', id: 'service-registry-design', label: 'Service Registry Design'},
        {type: 'doc', id: 'service-registry-status', label: 'Service Registry Status'},
        {type: 'doc', id: 'mcp-integration', label: 'MCP Integration'},
        {type: 'doc', id: 'syn-scanner-tuning', label: 'Syn Scanner Tuning'},
      ],
    },
  ],
};

export default sidebars;
