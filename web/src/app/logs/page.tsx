import LogsDashboard from '@/components/Logs/Dashboard';

export const metadata = {
    title: 'Logs - ServiceRadar',
    description: 'View and analyze OpenTelemetry logs',
};

export default function LogsPage() {
    return (
        <div className="p-6 max-w-full">
            <div className="mb-6">
                <h1 className="text-2xl font-bold text-gray-900 dark:text-white">Logs</h1>
                <p className="text-gray-600 dark:text-gray-400 mt-2">
                    View and analyze OpenTelemetry logs from your services
                </p>
            </div>
            <LogsDashboard />
        </div>
    );
}