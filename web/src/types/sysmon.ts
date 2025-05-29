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

// src/types/sysmon.ts

export interface SysmonDataPoint {
    timestamp: string;
    formattedTime: string;
    value: number;
}

export interface CpuCore {
    name: string;
    value: number;
}

export interface DiskDrive {
    name: string;
    used: number;
    size: number;
    usedPercent: number;
    warning: number;
    critical: number;
}

export interface SysmonData {
    cpu: {
        current: number;
        warning: number;
        critical: number;
        data: SysmonDataPoint[];
        unit: string;
        min: number;
        max: number;
        cores: CpuCore[];
        change: number;
    };
    memory: {
        current: number;
        warning: number;
        critical: number;
        total: number;
        used: number;
        data: SysmonDataPoint[];
        unit: string;
        min: number;
        max: number;
        change: number;
    };
    disk: {
        drives: DiskDrive[];
        data: SysmonDataPoint[];
        unit: string;
        warning: number;
        critical: number;
        min: number;
        max: number;
        change: number;
    };
}
