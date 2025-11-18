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

'use client';

import React from 'react';
import ReactJson from '@/components/Common/DynamicReactJson';
import { safeParseJsonObject } from '@/utils/json';

interface RawDataViewerProps {
    raw: string;
    theme?: 'rjv-default' | 'pop';
}

const RawDataViewer: React.FC<RawDataViewerProps> = ({ raw, theme = 'pop' }) => {
    const parsed = safeParseJsonObject(raw);

    if (parsed) {
        return (
            <ReactJson
                src={parsed}
                theme={theme}
                collapsed={false}
                displayDataTypes={false}
                enableClipboard={true}
                style={{
                    padding: '1rem',
                    borderRadius: '0.375rem',
                    backgroundColor: theme === 'pop' ? '#1C1B22' : '#f8f9fa',
                    maxHeight: '400px',
                    overflowY: 'auto'
                }}
            />
        );
    }

    return (
        <pre className="p-4 rounded text-xs font-mono whitespace-pre-wrap overflow-x-auto max-h-96 bg-gray-900 text-gray-100 dark:bg-gray-900/80">
            {raw}
        </pre>
    );
};

export default RawDataViewer;
