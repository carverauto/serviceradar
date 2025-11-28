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
import Link from "next/link";
import { unstable_noStore as noStore } from "next/cache";
import SightingsDashboard from "@/components/Identity/SightingsDashboard";

export const metadata = {
  title: "Identity Reconciliation - ServiceRadar",
  description: "Monitor network sightings, promotions, and audit history.",
};

type IdentityPageProps = {
  searchParams?: Promise<{ [key: string]: string | string[] | undefined }>;
};

export default async function IdentityPage({ searchParams }: IdentityPageProps) {
  noStore();

  const resolved = searchParams ? await searchParams : undefined;

  const prefillSightingId =
    typeof resolved?.sighting === "string" ? resolved.sighting : undefined;
  const historyActorFilter =
    typeof resolved?.history_actor === "string" ? resolved.history_actor : undefined;
  const historyPartitionFilter =
    typeof resolved?.history_partition === "string" ? resolved.history_partition : undefined;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Identity &amp; Sightings</h1>
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Review network sightings before promotion, trigger reconciliation, and audit override actions.
          </p>
        </div>
        <Link
          href="/identity/config"
          className="inline-flex items-center gap-2 rounded-md border border-blue-200 bg-blue-50 px-3 py-2 text-sm font-medium text-blue-700 hover:bg-blue-100 dark:border-blue-800 dark:bg-blue-900/30 dark:text-blue-100"
        >
          Manage identity config
        </Link>
      </div>
      <Suspense
        fallback={<div className="text-center p-6 text-gray-600 dark:text-gray-400">Loading identity data...</div>}
      >
        <SightingsDashboard
          prefillSightingId={prefillSightingId}
          historyActorDefault={historyActorFilter}
          historyPartitionDefault={historyPartitionFilter}
        />
      </Suspense>
    </div>
  );
}
