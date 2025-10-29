/*
 * Copyright 2025 Carver Automation.
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

import { ShieldPlus } from 'lucide-react';
import RoleGuard from '@/components/Auth/RoleGuard';

export default function EdgePackagesPage() {
  return (
    <RoleGuard requiredRoles={['admin']}>
      <div className="p-8 space-y-6">
        <div className="flex items-center gap-3">
          <ShieldPlus className="h-6 w-6 text-blue-500" />
          <div>
            <h1 className="text-2xl font-semibold">Edge Onboarding Packages</h1>
            <p className="text-sm text-muted-foreground">
              Manage download bundles and revocations for nested SPIRE pollers.
            </p>
          </div>
        </div>

        <div className="rounded-lg border border-dashed border-muted-foreground/40 bg-muted/30 p-6">
          <p className="text-sm leading-relaxed text-muted-foreground">
            API endpoints are live under <code>/api/admin/edge-packages</code> and
            the CLI now ships <code>edge-package-download</code> and <code>edge-package-revoke</code> helpers.
            A full UI workflow (list, issue, revoke) will land in the next iteration (tracked in GH-1903).
          </p>
        </div>
      </div>
    </RoleGuard>
  );
}
