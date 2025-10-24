type ServiceRow = Partial<Record<string, unknown>>;

const VALUE_KEYS = ['service_name', 'serviceName', 'name'] as const;
const ARRAY_VALUE_KEYS = ['services', 'service_names', 'serviceSet', 'service_set'] as const;

const SERVICE_NAME_MAP: Record<string, string> = {
    'db-event-writer': 'serviceradar-db-event-writer',
    'core': 'serviceradar-core',
    'sync': 'serviceradar-sync',
    'flowgger': 'serviceradar-flowgger',
    'zen': 'serviceradar-zen',
    'network_sweep': 'serviceradar-network-sweep',
    'kv': 'serviceradar-datasvc',
    'rperf-checker': 'serviceradar-rperf-checker',
    'mapper': 'serviceradar-mapper',
    'serviceradar-agent': 'serviceradar-agent',
    'ping': 'serviceradar-ping',
    'ssh': 'serviceradar-ssh',
    'trapd': 'serviceradar-trapd'
};

const EXTRA_SERVICES = ['serviceradar-core'];

const canonicalizeName = (name: string): string | undefined => {
    const trimmed = name.trim();
    if (!trimmed) {
        return undefined;
    }

    if (trimmed.toLowerCase().startsWith('serviceradar-')) {
        return trimmed;
    }

    const mapped = SERVICE_NAME_MAP[trimmed.toLowerCase()];
    if (mapped) {
        return mapped;
    }

    return trimmed;
};

const normalizeServiceName = (value: unknown): string | undefined => {
    if (typeof value !== 'string') {
        return undefined;
    }

    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
};

export const extractServiceNamesFromResults = (rows: unknown[]): string[] => {
    const sourceRows = Array.isArray(rows) ? rows : [];
    const seen = new Set<string>();
    const names: string[] = [];

    const registerNames = (candidates: (string | undefined)[]) => {
        candidates.forEach((candidate) => {
            if (!candidate) {
                return;
            }
            if (!seen.has(candidate)) {
                seen.add(candidate);
                names.push(candidate);
            }
        });
    };

    const extractArrayNames = (value: unknown): string[] => {
        if (Array.isArray(value)) {
            return value
                .map(normalizeServiceName)
                .filter((item): item is string => Boolean(item));
        }

        if (typeof value === 'string') {
            const trimmed = value.trim();
            if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
                try {
                    const parsed = JSON.parse(trimmed);
                    if (Array.isArray(parsed)) {
                        return parsed
                            .map(normalizeServiceName)
                            .filter((item): item is string => Boolean(item));
                    }
                } catch {
                    // fall through to treating the raw string as a single value
                }
            }

            const normalized = normalizeServiceName(value);
            return normalized ? [normalized] : [];
        }

        return [];
    };

    sourceRows.forEach((row) => {
        if (!row || typeof row !== 'object') {
            return;
        }

        const serviceRow = row as ServiceRow;

        for (const key of ARRAY_VALUE_KEYS) {
            if (!(key in serviceRow)) {
                continue;
            }
            const values = extractArrayNames(serviceRow[key]);
            if (values.length > 0) {
                registerNames(values);
                return;
            }
        }

        for (const key of VALUE_KEYS) {
            const candidate = normalizeServiceName(serviceRow[key]);
            if (!candidate) {
                continue;
            }

            registerNames([candidate]);
            return;
        }
    });

    return canonicalizeServiceList([...names, ...EXTRA_SERVICES]);
};

export const canonicalizeServiceList = (names: string[]): string[] => {
    if (!Array.isArray(names) || names.length === 0) {
        return [];
    }

    const seen = new Set<string>();
    const canonical: string[] = [];

    names.forEach((name) => {
        if (typeof name !== 'string') {
            return;
        }
        const normalized = canonicalizeName(name);
        if (!normalized) {
            return;
        }
        const lower = normalized.toLowerCase();
        if (seen.has(lower)) {
            return;
        }
        seen.add(lower);
        canonical.push(normalized);
    });

    return canonical.sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
};

export type SrqlPostQuery = <T>(query: string, cursor?: string, direction?: 'next' | 'prev') => Promise<T>;

export const SERVICES_SNAPSHOT_QUERY = 'in:services stats:"group_uniq_array(service_name) as services" limit:1';

export const fetchCanonicalServiceNames = async (
    postQuery: SrqlPostQuery
): Promise<string[]> => {
    const data = await postQuery<{ results?: unknown[] }>(SERVICES_SNAPSHOT_QUERY);
    return extractServiceNamesFromResults(data.results ?? []);
};

export const getServiceQueryValues = (serviceName: string): string[] => {
    if (typeof serviceName !== 'string') {
        return [];
    }

    const canonical = canonicalizeName(serviceName);
    if (!canonical) {
        return [];
    }

    const canonicalLower = canonical.toLowerCase();
    const aliases = Object.entries(SERVICE_NAME_MAP)
        .filter(([, mapped]) => mapped.toLowerCase() === canonicalLower)
        .map(([short]) => short);

    const values = new Set<string>();
    aliases.forEach((alias) => values.add(alias));
    values.add(canonical);

    return Array.from(values);
};
