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
      ],
    },
    {
      type: 'category',
      label: 'Get Started',
      items: [
        {type: 'doc', id: 'quickstart', label: 'ServiceRadar Quickstart'},
        {
          type: 'category',
          label: 'Guides & Tutorials',
          items: [
            {type: 'doc', id: 'custom-checkers'},
            {type: 'doc', id: 'srql-language-reference'},
            {type: 'doc', id: 'service-port-map'},
            {type: 'doc', id: 'web-ui'},
          ],
        },
        {
          type: 'category',
          label: 'Showcases',
          items: [
            {type: 'doc', id: 'rperf-monitoring'},
            {type: 'doc', id: 'proton'},
          ],
        },
        {
          type: 'category',
          label: 'HowTos',
          items: [
            {type: 'doc', id: 'configuration'},
            {type: 'doc', id: 'auth-configuration'},
            {type: 'doc', id: 'kv-configuration'},
            {type: 'doc', id: 'sync'},
            {type: 'doc', id: 'tls-security'},
            {type: 'doc', id: 'self-signed'},
            {type: 'doc', id: 'spiffe-identity', label: 'SPIFFE / SPIRE'},
            {type: 'doc', id: 'mcp-integration'},
            {type: 'doc', id: 'syn-scanner-tuning'},
          ],
        },
      ],
    },
    {
      type: 'category',
      label: 'Get Data In',
      items: [
        {type: 'doc', id: 'snmp', label: 'SNMP'},
        {type: 'doc', id: 'syslog', label: 'Syslog'},
        {type: 'doc', id: 'netflow', label: 'NetFlow'},
        {type: 'doc', id: 'otel', label: 'OTEL'},
        {type: 'doc', id: 'discovery', label: 'Discovery'},
        {type: 'doc', id: 'device-configuration', label: 'Device Configuration Reference'},
      ],
    },
    {
      type: 'category',
      label: 'Integrations',
      items: [
        {type: 'doc', id: 'armis', label: 'Armis'},
        {type: 'doc', id: 'netbox', label: 'NetBox'},
      ],
    },
    {
      type: 'category',
      label: 'Deployment',
      items: [
        {type: 'doc', id: 'installation', label: 'Bare Metal'},
        {type: 'doc', id: 'docker-setup', label: 'Docker'},
        {type: 'doc', id: 'helm-configuration', label: 'Kubernetes'},
      ],
    },
    {
      type: 'category',
      label: 'Troubleshooting',
      items: [
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting Guide'},
        {type: 'doc', id: 'agents', label: 'Agents & Demo Operations'},
        {type: 'doc', id: 'runbooks/sysmonvm-e2e', label: 'SysmonVM End-to-End'},
      ],
    },
  ],
};

export default sidebars;
