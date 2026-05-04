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
        {type: 'doc', id: 'tls-security', label: 'TLS / mTLS'},
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
        {type: 'doc', id: 'falco-integration', label: 'Falco Integration'},
        {type: 'doc', id: 'trivy-integration', label: 'Trivy Integration'},
        {type: 'doc', id: 'wasm-plugins', label: 'Wasm Plugins'},
      ],
    },
    {
      type: 'category',
      label: 'Data',
      items: [
        {type: 'doc', id: 'data-pipeline', label: 'Data Pipeline'},
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
      ],
    },
    {
      type: 'category',
      label: 'Operations',
      items: [
        {type: 'doc', id: 'tools', label: 'Tools Pod'},
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting'},
      ],
    },
  ],
};

export default sidebars;
