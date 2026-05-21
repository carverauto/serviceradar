import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import type * as Redocusaurus from 'redocusaurus';


// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'ServiceRadar',
  tagline: 'IT operations and network management platform',
  favicon: 'img/favicon.ico',

  url: 'https://docs.serviceradar.cloud',
  baseUrl: '',

  organizationName: 'carverauto',
  projectName: 'serviceradar',

  onBrokenLinks: 'throw',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  // Load the shared monospace font used across ServiceRadar web properties.
  stylesheets: [
    'https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&display=swap',
  ],

  // Add markdown configuration with Mermaid enabled
  markdown: {
    mermaid: true,
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  // Add theme-mermaid to the themes array
  themes: ['@docusaurus/theme-mermaid'],

  plugins: [
    [
      '@docusaurus/plugin-client-redirects',
      {
        // Redirects for pages removed or renamed in the docs reorganization,
        // so existing external/bookmarked links continue to resolve.
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
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
    [
      'redocusaurus',
      {
        // Plugin Options for loading OpenAPI files
        specs: [
          // Pass it a path to a local OpenAPI YAML file
          {
            // Redocusaurus will automatically bundle your spec into a single file during the build
            spec: 'openapi/index.yaml',
            route: '/api/',
          },
        ],
        // Theme Options for modifying how redoc renders them
        theme: {
          // Change with your site colors
          primaryColor: '#0369a1',
        },
      },
    ] satisfies Redocusaurus.PresetEntry,
  ],

  themeConfig: {
    image: 'img/serviceradar-social-card.png',
    navbar: {
      title: 'ServiceRadar',
      logo: {
        alt: 'ServiceRadar logo',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'tutorialSidebar',
          position: 'left',
          label: 'Docs',
        },
        {to: '/blog', label: 'Blog', position: 'left'},
        {
          href: 'https://github.com/carverauto/serviceradar',
          label: 'GitHub',
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
              label: 'Quickstart',
              to: '/docs/quickstart',
            },
          ],
        },
        {
          title: 'Community',
          items: [
            {
              label: 'GitHub Discussions',
              href: 'https://github.com/carverauto/serviceradar/discussions',
            },
            {
              label: 'Discord',
              href: 'https://discord.gg/dq6qRcmN',
            },
          ],
        },
        {
          title: 'More',
          items: [
            {
              label: 'GitHub',
              href: 'https://github.com/carverauto/serviceradar',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Carver Automation Corporation. Built with Docusaurus.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.palenight,
    },
    // Mermaid diagram theme configuration
    mermaid: {
      theme: { light: 'neutral', dark: 'dark' },
    },
  } satisfies Preset.ThemeConfig,
};

export default config;
