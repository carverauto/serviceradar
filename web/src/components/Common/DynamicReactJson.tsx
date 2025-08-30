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

import dynamic from 'next/dynamic';
import React from 'react';

// Dynamically import ReactJson to avoid SSR issues with document reference
const ReactJsonView = dynamic(() => import('@microlink/react-json-view'), {
    ssr: false,
    loading: () => <div className="p-4 text-gray-500">Loading JSON viewer...</div>
});

// Re-export with the same props interface as the original component
export default ReactJsonView;