import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import type * as Redocusaurus from 'redocusaurus';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'ServiceRadar',
  tagline: 'Network management, security, and observability',
  favicon: 'img/favicon.ico',

  // Canonical origin (must match Search Console + CNAME).
  url: 'https://docs.serviceradar.cloud',
  // GitHub Pages + Cloudflare: keep baseUrl rooted and set trailingSlash
  // explicitly. Leaving trailingSlash undefined makes GH Pages rewrite
  // /path → http://host/path/ (https→http), which floods GSC with
  // "Alternate page with proper canonical" and "Page with redirect".
  baseUrl: '/',
  trailingSlash: false,

  organizationName: 'carverauto',
  projectName: 'serviceradar',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  themes: ['@docusaurus/theme-mermaid'],

  // Tailwind v4 via PostCSS (utilities + theme only; no global Preflight).
  // Client redirects cover renamed/removed docs paths still in Google's crawl graph.
  plugins: [
    './src/plugins/tailwind-config.js',
    [
      '@docusaurus/plugin-client-redirects',
      {
        // Keep aligned with Search Console "Not found (404)" exports for docs.serviceradar.cloud.
        redirects: [
          {from: '/docs/god-view-topology', to: '/docs/network-topology'},
          {from: '/docs/topology-reset-rebuild', to: '/docs/network-topology'},
          {from: '/docs/self-signed', to: '/docs/tls-security'},
          {from: '/docs/falco-integration', to: '/docs/falco'},
          {from: '/docs/mtr-automation-rollout', to: '/docs/troubleshooting-guide'},
          {from: '/docs/cnpg-pg18-upgrade-and-search-policy', to: '/docs/cnpg-monitoring'},
          {from: '/docs/repository-layout', to: '/docs/architecture'},
          {from: '/docs/rust-bazel-deps', to: '/docs/intro'},
          {from: '/docs/camera-analysis-reference-worker', to: '/docs/sdks'},
          {from: '/docs/wifi-map-local-compose', to: '/docs/dashboard-sdk'},
          {from: '/docs/configuration', to: '/docs/configuration-system'},
          {from: '/docs/installation', to: '/docs/quickstart'},
          {from: '/docs/edge-agents', to: '/docs/edge-model'},
          {from: '/docs/agents', to: '/docs/agent-configuration'},
          {from: '/docs/cluster', to: '/docs/helm-configuration'},
          {from: '/docs/spiffe-identity', to: '/docs/workload-identity'},
          {from: '/docs/edge-onboarding', to: '/docs/edge-agent-onboarding'},
          {from: '/docs/kv-configuration', to: '/docs/configuration-system'},
          {from: '/specs/wasm-plugin-system', to: '/docs/wasm-plugins'},
          {from: '/docs/nco-validation-runs', to: '/docs/validation-runs'},
          {from: '/docs/nco-device-facts', to: '/docs/device-facts'},
        ],
      },
    ],
  ],

  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: './sidebars.ts',
        },
        blog: {
          showReadingTime: true,
        },
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
    [
      'redocusaurus',
      {
        specs: [
          {
            spec: 'openapi/index.yaml',
            route: '/api/',
          },
        ],
        theme: {
          // Brand green (dark-mode primary)
          primaryColor: '#3ecf87',
          primaryColorDark: '#3ecf87',
        },
      },
    ] satisfies Redocusaurus.PresetEntry,
  ],

  themeConfig: {
    image: 'img/serviceradar-social-card.png',
    colorMode: {
      defaultMode: 'dark',
      disableSwitch: true,
      respectPrefersColorScheme: false,
    },
    navbar: {
      title: 'ServiceRadar',
      logo: {
        alt: 'ServiceRadar logo',
        src: 'img/logo.svg',
      },
      hideOnScroll: false,
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Docs',
        },
        {
          href: 'https://serviceradar.cloud/blog',
          label: 'Blog',
          position: 'left',
        },
        {to: '/api/', label: 'API', position: 'left'},
        {
          href: 'https://developer.serviceradar.cloud',
          label: 'Developer',
          position: 'right',
        },
        {
          href: 'https://github.com/carverauto/serviceradar',
          label: 'GitHub',
          position: 'right',
        },
        {
          href: 'https://serviceradar.cloud',
          label: 'Cloud',
          position: 'right',
          className: 'navbar__link--cloud',
        },
        {
          href: 'https://demo.serviceradar.cloud',
          label: 'Live demo',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Docs',
          items: [
            {
              label: 'Introduction',
              to: '/docs/intro',
            },
            {
              label: 'Cloud Quickstart',
              to: '/docs/cloud-quickstart',
            },
            {
              label: 'Self-hosted Quickstart',
              to: '/docs/quickstart',
            },
            {
              label: 'API reference',
              to: '/api/',
            },
          ],
        },
        {
          title: 'Product',
          items: [
            {
              label: 'Marketing site',
              href: 'https://serviceradar.cloud',
            },
            {
              label: 'Developer portal',
              href: 'https://developer.serviceradar.cloud',
            },
            {
              label: 'Live demo',
              href: 'https://demo.serviceradar.cloud',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/carverauto/serviceradar',
            },
            {
              label: 'Discussions',
              href: 'https://github.com/carverauto/serviceradar/discussions',
            },
            {
              label: 'Discord',
              href: 'https://discord.gg/dq6qRcmN',
            },
          ],
        },
      ],
      copyright: `© ${new Date().getFullYear()} Carver Automation Corporation. All rights reserved.<br/>ServiceRadar® is a registered trademark of Carver Automation Corporation.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
    },
    mermaid: {
      theme: {light: 'neutral', dark: 'dark'},
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
