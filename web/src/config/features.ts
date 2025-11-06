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

import { env } from "next-runtime-env";

const TRUE_VALUES = new Set(["true", "1", "yes", "on", "enabled"]);
const FALSE_VALUES = new Set(["false", "0", "no", "off", "disabled"]);

const CLIENT_FLAG = "NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER";
const SERVER_FLAG = "FEATURE_DEVICE_SEARCH_PLANNER";

function parseBoolean(raw: string | undefined | null, fallback: boolean): boolean {
  if (!raw) {
    return fallback;
  }

  const normalized = raw.trim().toLowerCase();
  if (TRUE_VALUES.has(normalized)) {
    return true;
  }
  if (FALSE_VALUES.has(normalized)) {
    return false;
  }

  return fallback;
}

function readRawFlag(): string | undefined {
  if (typeof window === "undefined") {
    return process.env[SERVER_FLAG] ?? process.env[CLIENT_FLAG];
  }

  return env(CLIENT_FLAG) ?? undefined;
}

export function isDeviceSearchPlannerEnabled(): boolean {
  return parseBoolean(readRawFlag(), true);
}
