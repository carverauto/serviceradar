/**
 * Shared SRQL query fragments used by both client and server logic.
 * Keeping the definitions in one place helps the header, API routes,
 * and view components stay in sync.
 */
export const DEFAULT_DEVICES_QUERY =
    'in:devices time:last_24h sort:last_seen:desc limit:20';

export const SWEEP_DEVICES_QUERY =
    'in:devices discovery_sources:(sweep) time:last_24h sort:last_seen:desc';

export const DEFAULT_EVENTS_QUERY =
    'in:events time:last_24h sort:event_timestamp:desc limit:20';

export const DEFAULT_LOGS_QUERY =
    'in:logs time:last_24h sort:timestamp:desc limit:20';

export const DEFAULT_TRACES_QUERY =
    'in:otel_trace_summaries time:last_24h sort:timestamp:desc limit:20';

export const DEFAULT_METRICS_QUERY =
    'in:otel_metrics time:last_24h sort:timestamp:desc limit:20';

export const DISCOVERY_DEVICES_QUERY =
    'in:devices discovery_sources:* time:last_7d sort:last_seen:desc limit:50';

export const DISCOVERY_INTERFACES_QUERY =
    'in:interfaces time:last_7d sort:timestamp:desc limit:50';

export const SNMP_DEVICES_QUERY =
    'in:devices discovery_sources:(snmp) time:last_7d sort:last_seen:desc limit:20';

export const APPLICATION_SERVICES_QUERY =
    'in:services time:last_7d sort:last_seen:desc limit:50';

export const NETFLOW_DEFAULT_QUERY =
    'in:flows time:last_24h stats:"sum(bytes_total) as total_bytes by connection.src_endpoint_ip" sort:total_bytes:desc limit:25';

/**
 * Build a sweep query string suitable for showing in the header.
 * The sweep API passes the limit separately, but including it in the
 * rendered query helps users understand how much data was fetched.
 */
export const buildSweepQueryWithLimit = (limit: number | null | undefined): string => {
    if (typeof limit === 'number' && Number.isFinite(limit)) {
        return `${SWEEP_DEVICES_QUERY} limit:${limit}`;
    }
    return SWEEP_DEVICES_QUERY;
};
