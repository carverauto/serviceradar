// src/components/NetworkStatus.d.ts
import { ServiceDetails } from "@/types/types";

interface PingStatusProps {
    details: ServiceDetails | string;
    nodeId?: string;
    serviceName?: string;
}

interface ICMPSummaryProps {
    hosts: {
        available: boolean;
        response_time?: number;
    }[];
}

interface NetworkSweepICMPProps {
    sweepData: {
        hosts?: {
            icmp_status?: {
                available: boolean;
                round_trip?: number;
            };
        }[];
    };
}

export const PingStatus: React.FC<PingStatusProps>;
export const ICMPSummary: React.FC<ICMPSummaryProps>;
export const NetworkSweepICMP: React.FC<NetworkSweepICMPProps>;