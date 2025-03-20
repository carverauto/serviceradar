import { Service } from "@/types/types";

interface NetworkSweepViewProps {
    nodeId: string;
    service: Service;
    standalone?: boolean;
}

declare const NetworkSweepView: React.FC<NetworkSweepViewProps>;
export default NetworkSweepView;