import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

const iconProps = {
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.75,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
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
        <header className={clsx('hero hero--primary', styles.heroBanner)}>
            <div className="container">
                <Heading as="h1" className="hero__title">
                    Run Your Network &amp; IT Operations
                </Heading>
                <p className="hero__subtitle">
                    ServiceRadar is an IT operations and network management platform with
                    built-in observability and security analytics — built to reach the edge.
                </p>
                <div className={styles.buttons}>
                    <Link
                        className="button button--secondary button--lg"
                        to="/docs/intro">
                        Get Started →
                    </Link>
                    <Link
                        className="button button--outline button--lg"
                        to="/docs/quickstart">
                        Quickstart
                    </Link>
                </div>
            </div>
        </header>
    );
}

const features = [
    {
        title: 'Network Management',
        Icon: NetworkIcon,
        description:
            'Discover, map, and monitor your network — SNMP, NetFlow, BGP, sweeps, and topology, all the way to the edge.',
    },
    {
        title: 'IT Operations',
        Icon: OperationsIcon,
        description:
            'Track devices, services, and infrastructure health with agent-based monitoring built for hard-to-reach environments.',
    },
    {
        title: 'Observability',
        Icon: ObservabilityIcon,
        description:
            'Collect metrics, traces, and logs with OpenTelemetry, and query everything with SRQL.',
    },
    {
        title: 'Security Analytics',
        Icon: SecurityIcon,
        description:
            'Ingest syslog, runtime security events, and vulnerability scans into one normalized, alertable event store.',
    },
];

function HomepageFeatures() {
    return (
        <section className={styles.features}>
            <div className="container">
                <div className="row">
                    {features.map((feature, idx) => (
                        <div key={idx} className={clsx('col col--3')}>
                            <div className={styles.featureCard}>
                                <span className={styles.featureIcon}>
                                    <feature.Icon />
                                </span>
                                <Heading as="h3" className={styles.featureTitle}>
                                    {feature.title}
                                </Heading>
                                <p className={styles.featureDescription}>
                                    {feature.description}
                                </p>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </section>
    );
}

export default function Home(): ReactNode {
    const {siteConfig} = useDocusaurusContext();
    return (
        <Layout
            title={siteConfig.title}
            description="ServiceRadar — an IT operations and network management platform with built-in observability and security analytics.">
            <HomepageHeader />
            <main>
                <HomepageFeatures />
            </main>
        </Layout>
    );
}
