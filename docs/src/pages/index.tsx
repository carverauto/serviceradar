import type {ReactNode} from 'react';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';

const iconProps = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.75,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  width: 20,
  height: 20,
};

function NetworkIcon() {
  return (
    <svg {...iconProps} aria-hidden="true">
      <circle cx="6" cy="6" r="2.5" />
      <circle cx="18" cy="6" r="2.5" />
      <circle cx="12" cy="18" r="2.5" />
      <path d="M8.4 6h7.2M7.7 8.1l3 7.8M16.3 8.1l-3 7.8" />
    </svg>
  );
}

function OperationsIcon() {
  return (
    <svg {...iconProps} aria-hidden="true">
      <rect x="3" y="4" width="18" height="7" rx="1.5" />
      <rect x="3" y="13" width="18" height="7" rx="1.5" />
      <path d="M6.5 7.5h.01M6.5 16.5h.01" />
    </svg>
  );
}

function ObservabilityIcon() {
  return (
    <svg {...iconProps} aria-hidden="true">
      <path d="M3 12h4l3 7 4-14 3 7h4" />
    </svg>
  );
}

function SecurityIcon() {
  return (
    <svg {...iconProps} aria-hidden="true">
      <path d="M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6z" />
      <path d="M9 12l2 2 4-4" />
    </svg>
  );
}

function HomepageHeader() {
  return (
    <header className="sr-docs-hero">
      <div className="sr-docs-hero__glow" aria-hidden="true" />
      <div className="sr-docs-hero__inner">
        <div className="sr-docs-hero__copy">
          <p className="sr-docs-hero__eyebrow">Product documentation</p>
          <h1 className="sr-docs-hero__title">ServiceRadar docs</h1>
          <p className="sr-docs-hero__lede">
            Install, operate, and extend ServiceRadar — network management, edge
            agents, observability, and security — with the same platform design
            language as the product.
          </p>
          <div className="sr-docs-hero__actions">
            <Link className="sr-docs-btn sr-docs-btn--primary" to="/docs/cloud-quickstart">
              Cloud quickstart
            </Link>
            <Link className="sr-docs-btn sr-docs-btn--secondary" to="/docs/quickstart">
              Self-hosted quickstart
            </Link>
            <Link
              className="sr-docs-btn sr-docs-btn--secondary"
              href="https://developer.serviceradar.cloud">
              Developer portal
            </Link>
          </div>
        </div>
      </div>
    </header>
  );
}

const features = [
  {
    title: 'Network management',
    Icon: NetworkIcon,
    description:
      'Discover, map, and monitor your network — SNMP, NetFlow, BGP, sweeps, and topology out to the edge.',
  },
  {
    title: 'IT operations',
    Icon: OperationsIcon,
    description:
      'Track devices, services, and infrastructure health with agents built for hard-to-reach environments.',
  },
  {
    title: 'Observability',
    Icon: ObservabilityIcon,
    description:
      'Collect metrics, traces, and logs with OpenTelemetry, and query everything with SRQL.',
  },
  {
    title: 'Security analytics',
    Icon: SecurityIcon,
    description:
      'Ingest syslog, runtime security events, and vulnerability scans into one normalized event store.',
  },
];

function HomepageFeatures() {
  return (
    <section className="sr-docs-section">
      <div className="sr-docs-section__inner">
        <div className="sr-docs-section__intro">
          <p className="sr-docs-section__eyebrow">How it fits together</p>
          <h2 className="sr-docs-section__title">What you can run</h2>
          <p className="sr-docs-section__lede">
            Operator guides and architecture notes for the same surfaces you use
            in the product and developer portal.
          </p>
        </div>

        <div className="sr-docs-panel">
          <div className="sr-docs-panel__head">
            <p className="sr-docs-panel__head-title">Documentation map</p>
            <p className="sr-docs-panel__head-meta">
              Start with deploy and architecture, then go deep on operations and security
            </p>
          </div>
          <div className="sr-docs-panel__grid">
            {features.map((feature) => (
              <div key={feature.title} className="sr-docs-panel__cell">
                <span className="sr-docs-panel__icon">
                  <feature.Icon />
                </span>
                <h3 className="sr-docs-panel__cell-title">{feature.title}</h3>
                <p className="sr-docs-panel__cell-body">{feature.description}</p>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

export default function Home(): ReactNode {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={`${siteConfig.title} docs`}
      description="ServiceRadar documentation — network management, security, and observability.">
      <HomepageHeader />
      <main>
        <HomepageFeatures />
      </main>
    </Layout>
  );
}
