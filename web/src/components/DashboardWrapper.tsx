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

// src/components/DashboardWrapper.tsx (client-side)
"use client";

import { useEffect, useState } from "react";
import { useAuth } from "./AuthProvider";
import Dashboard from "./Dashboard";
import { SystemStatus } from "@/types/types";

export default function DashboardWrapper({
  initialData,
}: {
  initialData: SystemStatus | null;
}) {
  const { token } = useAuth();
  const [data, setData] = useState<SystemStatus | null>(initialData);

  useEffect(() => {
    async function fetchData() {
      if (token) {
        try {
          console.log("Fetching dashboard data with token");

          // Direct fetch from the Next.js API route
          const response = await fetch("/api/status", {
            headers: {
              "Content-Type": "application/json",
              Authorization: `Bearer ${token}`,
            },
            cache: "no-store",
            credentials: "include",
          });

          if (!response.ok) {
            throw new Error(`API request failed: ${response.status}`);
          }

          const updatedData = await response.json();
          setData(updatedData);
        } catch (err) {
          console.error("Error fetching dashboard data:", err);
        }
      }
    }

    fetchData();

    // Optional: Set up a polling interval
    const intervalId = setInterval(fetchData, 10000); // Every 10 seconds

    // Clean up interval on unmount
    return () => clearInterval(intervalId);
  }, [token]);

  return <Dashboard initialData={data} />;
}
