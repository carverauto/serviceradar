import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const config: Config = {
  title: 'ServiceRadar',
  tagline: 'ServiceRadar Docs',
  favicon: 'img/favicon.ico',

  url: 'https://docs.serviceradar.cloud',
  baseUrl: '/serviceradar/',

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
      options: {
        themeVariables: {
          primaryColor: '#10b981',
          primaryTextColor: '#ffffff',
          primaryBorderColor: '#047857',
          lineColor: '#6ee7b7',
          secondaryColor: '#059669',
          secondaryTextColor: '#ffffff',
          tertiaryColor: '#34d399',
          tertiaryTextColor: '#1f2937',
          background: '#1f2937',
          mainBkg: '#10b981',
          textColor: '#d1fae5',
          darkMode: true
        }
      }
    },
  } satisfies Preset.ThemeConfig,
};

export default config;