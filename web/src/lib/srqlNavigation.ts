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

export interface SrqlNavigationContext {
    activeQuery: string;
    viewPath: string | null;
    viewId: string | null;
}

const normalize = (value: string): string =>
    value.replace(/\s+/g, ' ').trim();

type ViewMatcher = (query: string) => boolean;

const VIEW_QUERY_MATCHERS: Record<string, ViewMatcher> = {
    'devices:inventory': (query) =>
        normalize(query).toLowerCase().startsWith('in:devices'),
    'network:discovery': (query) =>
        /\bin:devices\b/i.test(query) &&
        /discovery_sources:\*/i.test(query),
    'network:sweeps': (query) =>
        /\bin:sweep_results\b/i.test(query) ||
        /discovery_sources:\(sweep\)/i.test(query),
    'network:snmp': (query) =>
        /\bin:devices\b/i.test(query) &&
        /discovery_sources:\(snmp\)/i.test(query),
};

export const shouldReuseViewForSearch = (
    { activeQuery, viewPath, viewId }: SrqlNavigationContext,
    nextQuery: string
): boolean => {
    if (!viewPath) {
        return false;
    }

    const normalizedNext = normalize(nextQuery);
    if (!normalizedNext) {
        return false;
    }

    if (viewId) {
        const matcher = VIEW_QUERY_MATCHERS[viewId];
        if (matcher) {
            if (matcher(normalizedNext)) {
                return true;
            }
        }
    }

    const normalizedActive = normalize(activeQuery);

    return normalizedActive.length > 0 && normalizedActive === normalizedNext;
};

export default shouldReuseViewForSearch;
