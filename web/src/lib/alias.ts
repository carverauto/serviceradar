/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { DeviceAliasHistory, DeviceAliasRecord } from "@/types/devices";

type ParsedAliasEntry = {
    key: string;
    lastSeen?: string;
};

export type AliasMetadataSnapshot = {
    lastSeenAt?: string;
    currentServiceId?: string;
    previousServiceId?: string;
    currentIP?: string;
    previousIP?: string;
    collectorIP?: string;
    previousCollectorIP?: string;
    services: Array<{ id: string; lastSeen?: string }>;
    ips: Array<{ ip: string; lastSeen?: string }>;
};

const parseAliasPairs = (value?: unknown): ParsedAliasEntry[] => {
    if (typeof value !== "string" || value.trim().length === 0) {
        return [];
    }

    const entries = new Map<string, string | undefined>();

    value.split(",").forEach((part) => {
        const trimmed = part.trim();
        if (!trimmed) {
            return;
        }

        const [rawKey, rawTimestamp] = trimmed.split("=");
        const key = rawKey?.trim();
        if (!key) {
            return;
        }

        const timestamp = rawTimestamp?.trim();
        entries.set(key, timestamp || undefined);
    });

    return Array.from(entries.entries()).map(([key, lastSeen]) => ({ key, lastSeen }));
};

const ensureAliasEntry = (
    entries: ParsedAliasEntry[],
    candidate?: string,
    lastSeen?: string,
): ParsedAliasEntry[] => {
    const value = candidate?.trim();
    if (!value) {
        return entries;
    }

    const existingIndex = entries.findIndex((entry) => entry.key === value);
    if (existingIndex >= 0) {
        if (!entries[existingIndex].lastSeen && lastSeen) {
            const next = [...entries];
            next[existingIndex] = {
                key: entries[existingIndex].key,
                lastSeen,
            };
            return next;
        }
        return entries;
    }

    return [{ key: value, lastSeen }, ...entries];
};

const sortByTimestampDesc = <T extends { lastSeen?: string }>(entries: T[]): T[] => {
    const parseTimestamp = (value?: string): number => {
        if (!value) {
            return Number.NEGATIVE_INFINITY;
        }
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) {
            return Number.NEGATIVE_INFINITY;
        }
        return date.getTime();
    };

    return [...entries].sort((a, b) => parseTimestamp(b.lastSeen) - parseTimestamp(a.lastSeen));
};

const limitHistory = <T,>(entries: T[], limit = 12): T[] => entries.slice(0, limit);

/**
 * Extracts alias metadata snapshot details from a device metadata map.
 */
export const extractAliasMetadata = (
    metadata?: Record<string, unknown>,
): AliasMetadataSnapshot | null => {
    if (!metadata || Object.keys(metadata).length === 0) {
        return null;
    }

    const getString = (key: string): string | undefined => {
        const value = metadata[key];
        if (typeof value !== "string") {
            return undefined;
        }
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : undefined;
    };

    const lastSeenAt = getString("_alias_last_seen_at");
    const collectorIP = getString("_alias_collector_ip");
    const currentServiceId = getString("_alias_last_seen_service_id");
    const currentIP = getString("_alias_last_seen_ip");
    const previousServiceId = getString("previous_service_id");
    const previousIP = getString("previous_ip");
    const previousCollectorIP = getString("previous_collector_ip");

    let services = parseAliasPairs(getString("alias_services"));
    services = ensureAliasEntry(services, currentServiceId, lastSeenAt);
    services = sortByTimestampDesc(services);
    services = limitHistory(services);

    let ips = parseAliasPairs(getString("alias_ips"));
    ips = ensureAliasEntry(ips, currentIP, lastSeenAt);
    ips = sortByTimestampDesc(ips);
    ips = limitHistory(ips);

    return {
        lastSeenAt,
        collectorIP,
        currentServiceId,
        previousServiceId,
        currentIP,
        previousIP,
        previousCollectorIP,
        services: services.map(({ key, lastSeen }) => ({ id: key, lastSeen })),
        ips: ips.map(({ key, lastSeen }) => ({ ip: key, lastSeen })),
    };
};

const coerceAliasRecords = (
    entries: Array<{ id?: string; ip?: string; lastSeen?: string }>,
): DeviceAliasRecord[] | undefined => {
    if (!entries.length) {
        return undefined;
    }
    return entries.map((entry) => {
        const record: DeviceAliasRecord = {};
        if (entry.id) {
            record.id = entry.id;
        }
        if (entry.ip) {
            record.ip = entry.ip;
        }
        if (entry.lastSeen) {
            record.last_seen_at = entry.lastSeen;
        }
        return record;
    });
};

/**
 * Builds a DeviceAliasHistory from device metadata. Returns null if no alias fields are present.
 */
export const buildAliasHistoryFromMetadata = (
    metadata?: Record<string, unknown>,
): DeviceAliasHistory | null => {
    const snapshot = extractAliasMetadata(metadata);
    if (!snapshot) {
        return null;
    }

    if (
        !snapshot.lastSeenAt &&
        !snapshot.collectorIP &&
        !snapshot.currentServiceId &&
        !snapshot.currentIP &&
        snapshot.services.length === 0 &&
        snapshot.ips.length === 0
    ) {
        return null;
    }

    return {
        last_seen_at: snapshot.lastSeenAt,
        collector_ip: snapshot.collectorIP,
        current_service_id: snapshot.currentServiceId,
        current_ip: snapshot.currentIP,
        services: coerceAliasRecords(snapshot.services)?.map((record) => ({
            id: record.id,
            last_seen_at: record.last_seen_at,
        })),
        ips: coerceAliasRecords(snapshot.ips)?.map((record) => ({
            ip: record.ip,
            last_seen_at: record.last_seen_at,
        })),
    };
};
