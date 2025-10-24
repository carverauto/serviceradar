type ServiceRow = Partial<Record<string, unknown>>;

const VALUE_KEYS = ['service_name', 'serviceName', 'name'] as const;
const ARRAY_VALUE_KEYS = ['services', 'service_names', 'serviceSet', 'service_set'] as const;

const normalizeServiceName = (value: unknown): string | undefined => {
    if (typeof value !== 'string') {
        return undefined;
    }

    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : undefined;
};

export const extractServiceNamesFromResults = (rows: unknown[]): string[] => {
    if (!Array.isArray(rows) || rows.length === 0) {
        return [];
    }

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

    rows.forEach((row) => {
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

    return names.sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
};
