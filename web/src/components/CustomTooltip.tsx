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

import { TooltipProps } from 'recharts';
import { NameType, ValueType } from 'recharts/types/component/DefaultTooltipContent';

// Define the shape of our data point
interface DataPoint {
    timestamp: number;
    status: number;
    tooltipTime: string;
    is_healthy: boolean;
}

// Create a properly typed CustomTooltip component
const CustomTooltip = ({
                           active,
                           payload
                       }: TooltipProps<ValueType, NameType>) => {
    if (!active || !payload || !payload.length) return null;

    // Cast payload data to our expected type
    const data = payload[0].payload as DataPoint;

    return (
        <div className="bg-white dark:bg-gray-700 p-4 rounded shadow-lg border dark:border-gray-600 dark:text-gray-100">
            <p className="text-sm font-semibold">{data.tooltipTime}</p>
            <p className="text-sm">
                Status: {data.status === 1 ? 'Online' : 'Offline'}
            </p>
        </div>
    );
};

export default CustomTooltip;