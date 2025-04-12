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

import { Suspense } from "react";
import EnvironmentMetricsWrapper from "@/components/Metrics/EnvironmentMetricsWrapper";

export const metadata = {
    title: "Environmental Metrics - ServiceRadar",
    description: "Environmental monitoring metrics dashboard"
};

export default function MetricsPage() {
    return (
        <div className="space-y-6">
            <h1 className="text-2xl font-bold mb-6">Environmental Metrics</h1>
            <Suspense fallback={<div>Loading metrics dashboard...</div>}>
                <EnvironmentMetricsWrapper />
            </Suspense>
        </div>
    );
}