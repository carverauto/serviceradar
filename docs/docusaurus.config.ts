import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';
import type * as Redocusaurus from 'redocusaurus';


// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'ServiceRadar',
  tagline: 'ServiceRadar Docs',
  favicon: 'img/favicon.ico',

  url: 'https://docs.serviceradar.cloud',
  baseUrl: '',

  organizationName: 'carverauto',
  projectName: 'serviceradar',

  onBrokenLinks: 'throw',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  // Add markdown configuration with Mermaid enabled
  markdown: {
    mermaid: true,
  },

  // Add theme-mermaid to the themes array
  themes: ['@docusaurus/theme-mermaid'],

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
          primaryColor: '#1890ff',
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
          label: 'Tutorial',
        },
        {to: '/blog', label: 'Blog', position: 'left'},
        {
          href: 'https://demo.serviceradar.cloud',
          label: 'Demo',
          position: 'left',
        },
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
              label: 'Tutorial',
              to: '/docs/intro',
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
      darkTheme: prismThemes.dracula,
    },
    // Optional: Add Mermaid theme configuration
    mermaid: {
      theme: { light: 'neutral', dark: 'base' },
    },
  } satisfies Preset.ThemeConfig,
};

export default config;