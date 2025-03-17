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

// src/env.js
import { createRuntimeEnv } from 'next-runtime-env';

// Create environment with server runtime variables
export const env = createRuntimeEnv({
  // List the server-only variables you need access to
  serverOnly: ['API_KEY', 'AUTH_ENABLED'],
  
  // Optional: List any client-side variables
  clientSide: ['NEXT_PUBLIC_API_URL', 'NEXT_PUBLIC_AUTH_ENABLED', 'AUTH_ENABLED'],
});
