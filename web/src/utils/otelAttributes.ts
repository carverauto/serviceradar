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

const openerToCloser: Record<string, string> = {
  '[': ']',
  '{': '}',
  '(': ')'
};

const closers = new Set(Object.values(openerToCloser));

export function parseOtelAttributes(attrString: string): Record<string, string> {
  if (!attrString || attrString.trim() === '') {
    return {};
  }

  const attrs: Record<string, string> = {};
  const input = attrString.trim();

  let buffer = '';
  let key: string | null = null;
  const stack: string[] = [];
  let inQuotes = false;

  const flush = () => {
    if (key === null) {
      buffer = '';
      return;
    }

    const trimmedKey = key.trim();
    const trimmedValue = buffer.trim();

    if (trimmedKey !== '') {
      attrs[trimmedKey] = trimmedValue;
    }

    key = null;
    buffer = '';
  };

  for (let i = 0; i < input.length; i++) {
    const char = input[i];
    const prev = i > 0 ? input[i - 1] : '';

    if (char === '"' && prev !== '\\') {
      inQuotes = !inQuotes;
      buffer += char;
      continue;
    }

    if (!inQuotes) {
      if (openerToCloser[char]) {
        stack.push(openerToCloser[char]);
        buffer += char;
        continue;
      }

      if (closers.has(char)) {
        if (stack.length > 0 && stack[stack.length - 1] === char) {
          stack.pop();
        }
        buffer += char;
        continue;
      }

      if (char === '=' && key === null && stack.length === 0) {
        key = buffer;
        buffer = '';
        continue;
      }

      if (char === ',' && stack.length === 0) {
        flush();
        continue;
      }
    }

    buffer += char;
  }

  if (buffer.length > 0 || key !== null) {
    flush();
  }

  return attrs;
}

