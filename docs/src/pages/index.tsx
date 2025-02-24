import type {ReactNode} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';

import styles from './index.module.css';

function HomepageHeader() {
    const {siteConfig} = useDocusaurusContext();
    return (
        <header className={clsx('hero hero--primary', styles.heroBanner)}>
            <div className="container">
                <Heading as="h1" className="hero__title">
                    Monitor Your Infrastructure Anywhere
                </Heading>
                <p className="hero__subtitle">
                    A distributed network monitoring system designed for infrastructure and services in hard to reach places
                </p>
                <div className={styles.buttons}>
                    <Link
                        className="button button--secondary button--lg"
                        to="/docs/intro">
                        Get Started →
                    </Link>
                </div>
            </div>
        </header>
    );
}

function HomepageFeatures() {
    const features = [
        {
            title: 'Real-time Monitoring',
            description: 'Monitor services in hard-to-reach places with real-time alerts and comprehensive dashboards.',
            icon: '🔍'
        },
        {
            title: 'SNMP Integration',
            description: 'Deep network monitoring with SNMP support and detailed metrics visualization.',
            icon: '📊'
        },
        {
            title: 'Secure Access',
            description: 'Enterprise-grade security with mutual TLS authentication and role-based access control.',
            icon: '🔒'
        },
        {
            title: 'Cloud Integration',
            description: 'Cloud-based alerting ensures you stay informed even during network or power outages.',
            icon: '☁️'
        }
    ];

    return (
        <section className={styles.features}>
            <div className="container">
                <div className="row">
                    {features.map((feature, idx) => (
                        <div key={idx} className={clsx('col col--3')}>
                            <div className="text--center padding-horiz--md">
                                <div className={styles.featureIcon}>{feature.icon}</div>
                                <Heading as="h3">{feature.title}</Heading>
                                <p>{feature.description}</p>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </section>
    );
}

function HomepageStats() {
    const stats = [
        { label: 'Active installations', value: '8,000+' },
        { label: 'Nodes monitored', value: '100k+' },
        { label: 'Uptime', value: '99.9%' },
        { label: 'Data points collected', value: '1B+' }
    ];

    return (
        <section className={styles.stats}>
            <div className="container">
                <div className="row">
                    {stats.map((stat, idx) => (
                        <div key={idx} className={clsx('col col--3')}>
                            <div className="text--center">
                                <Heading as="h2" className={styles.statValue}>
                                    {stat.value}
                                </Heading>
                                <p className={styles.statLabel}>{stat.label}</p>
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
            description="Monitor your infrastructure anywhere with ServiceRadar - distributed network monitoring system">
            <HomepageHeader />
            <main>
                <HomepageFeatures />
            </main>
        </Layout>
    );
}