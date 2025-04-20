// src/components/Metrics/system-metrics.d.ts

import { SysmonData } from '@/types/sysmon';

interface SystemMetricsProps {
    pollerId: string;
    initialData?: SysmonData | null;  // Make initialData accept SysmonData, null, or undefined
}

declare const SystemMetrics: React.FC<SystemMetricsProps>;

export default SystemMetrics;