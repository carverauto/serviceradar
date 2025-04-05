// Import the types from recharts
import { TooltipProps } from 'recharts';
import { NameType, ValueType } from 'recharts/types/component/DefaultTooltipContent';

// Define the shape of our data point
interface DataPoint {
    timestamp: number;
    status: number;
    tooltipTime: string;
    is_healthy: boolean;
}

// Create a properly typed CustomTooltip component
const CustomTooltip = ({
                           active,
                           payload
                       }: TooltipProps<ValueType, NameType>) => {
    if (!active || !payload || !payload.length) return null;

    // Cast payload data to our expected type
    const data = payload[0].payload as DataPoint;

    return (
        <div className="bg-white dark:bg-gray-700 p-4 rounded shadow-lg border dark:border-gray-600 dark:text-gray-100">
            <p className="text-sm font-semibold">{data.tooltipTime}</p>
            <p className="text-sm">
                Status: {data.status === 1 ? 'Online' : 'Offline'}
            </p>
        </div>
    );
};

export default CustomTooltip;