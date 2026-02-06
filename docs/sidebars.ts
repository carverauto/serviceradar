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
      items: [{type: 'doc', id: 'intro', label: 'Introduction'}, {type: 'doc', id: 'quickstart', label: 'Quickstart'}, {type: 'doc', id: 'architecture', label: 'Architecture'}],
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
        {type: 'doc', id: 'wasm-plugins', label: 'Wasm Plugins'},
      ],
    },
    {
      type: 'category',
      label: 'Data',
      items: [{type: 'doc', id: 'data-pipeline', label: 'Data Pipeline'}, {type: 'doc', id: 'srql-language-reference', label: 'SRQL Reference'}],
    },
    {
      type: 'category',
      label: 'Operations',
      items: [
        {type: 'doc', id: 'tools', label: 'Tools Pod'},
        {type: 'doc', id: 'troubleshooting-guide', label: 'Troubleshooting'},
        {type: 'doc', id: 'agents', label: 'Demo Ops'},
      ],
    },
    {
      type: 'category',
      label: 'Runbooks',
      items: [
        {type: 'doc', id: 'runbooks/docker-compose-login-500', label: 'Docker Login 500'},
        {type: 'doc', id: 'runbooks/age-graph-readiness', label: 'AGE Graph Readiness'},
      ],
    },
  ],
};

export default sidebars;
