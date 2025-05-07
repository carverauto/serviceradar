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
