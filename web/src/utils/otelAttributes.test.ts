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

import { describe, expect, it } from 'vitest';
import { parseOtelAttributes } from './otelAttributes';

describe('parseOtelAttributes', () => {
  it('keeps attribute values containing JSON arrays intact', () => {
    const raw =
      'device_id=13663,primary_ip=10.181.181.117,total_ips=3,all_ips=["10.181.181.117","10.181.181.118","10.181.181.119"]';

    const parsed = parseOtelAttributes(raw);

    expect(parsed).toEqual({
      device_id: '13663',
      primary_ip: '10.181.181.117',
      total_ips: '3',
      all_ips: '["10.181.181.117","10.181.181.118","10.181.181.119"]'
    });
  });
});

