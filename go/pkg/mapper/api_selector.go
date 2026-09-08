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

package mapper

import "strings"

func selectNamedBaseURLConfigs[T any](
	job *DiscoveryJob,
	all []T,
	namesOption string,
	urlsOption string,
	nameFn func(T) string,
	baseURLFn func(T) string,
) ([]T, string) {
	if len(all) == 0 || job == nil || job.Params == nil {
		return all, ""
	}

	opts := job.Params.Options
	if len(opts) == 0 {
		return all, ""
	}

	allowedNames := parseCSVSet(opts[namesOption], true)
	allowedURLs := parseCSVSet(opts[urlsOption], false)
	if len(allowedNames) == 0 && len(allowedURLs) == 0 {
		return all, ""
	}

	filtered := filterNamedBaseURLConfigs(all, allowedNames, allowedURLs, nameFn, baseURLFn)
	return filtered, opts[namesOption] + "|" + opts[urlsOption]
}

func filterNamedBaseURLConfigs[T any](
	all []T,
	allowedNames map[string]bool,
	allowedURLs map[string]bool,
	nameFn func(T) string,
	baseURLFn func(T) string,
) []T {
	filtered := make([]T, 0, len(all))

	for _, item := range all {
		nameKey := strings.ToLower(strings.TrimSpace(nameFn(item)))
		urlKey := normalizeURLKey(baseURLFn(item))

		if allowedNames[nameKey] || allowedURLs[urlKey] {
			filtered = append(filtered, item)
		}
	}

	return filtered
}
