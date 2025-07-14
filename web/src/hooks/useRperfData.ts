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

import { useQuery } from '@tanstack/react-query';
import { useAuth } from '@/components/AuthProvider';
import { RperfMetric } from '@/types/rperf';

interface UseRperfDataOptions {
    pollerId: string;
    startTime: Date;
    endTime: Date;
    enabled?: boolean;
}

export const useRperfData = ({ pollerId, startTime, endTime, enabled = true }: UseRperfDataOptions) => {
    const { token } = useAuth();

    return useQuery({
        queryKey: [
            'rperf', 
            pollerId, 
            // Round to nearest minute for better cache hits
            Math.floor(startTime.getTime() / 60000), 
            Math.floor(endTime.getTime() / 60000)
        ],
        queryFn: async (): Promise<RperfMetric[]> => {
            console.log(`[React Query] Fetching rperf for ${pollerId} from ${startTime.toISOString()} to ${endTime.toISOString()}`);
            
            const url = `/api/pollers/${pollerId}/rperf?start=${startTime.toISOString()}&end=${endTime.toISOString()}`;
            const response = await fetch(url, {
                headers: {
                    'Content-Type': 'application/json',
                    ...(token && { Authorization: `Bearer ${token}` }),
                },
            });

            if (!response.ok) {
                console.error(`RPerf API error for poller ${pollerId}: ${response.status}`);
                throw new Error(`Failed to fetch rperf data: ${response.status}`);
            }

            const data = await response.json();
            console.log(`[React Query] Got ${data.length} rperf metrics for ${pollerId}`);
            return data;
        },
        enabled: enabled && !!token,
        staleTime: 30000, // 30 seconds
        refetchInterval: 60000, // 60 seconds
    });
};