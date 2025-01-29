import React from 'react';
import * as XLSX from 'xlsx';
import { Download } from 'lucide-react';

const ExportButton = ({ sweepDetails }) => {
    const handleExport = () => {
        // Create workbook
        const wb = XLSX.utils.book_new();

        // Create summary sheet
        const summaryData = [
            {
                Network: sweepDetails.network,
                'Total Hosts': sweepDetails.total_hosts,
                'Available Hosts': sweepDetails.available_hosts,
                'Last Sweep': new Date(sweepDetails.last_sweep * 1000).toLocaleString(),
                'Available %':
                    (
                        (sweepDetails.available_hosts / sweepDetails.total_hosts) *
                        100
                    ).toFixed(2) + '%',
            },
        ];
        const summarySheet = XLSX.utils.json_to_sheet(summaryData);
        XLSX.utils.book_append_sheet(wb, summarySheet, 'Summary');

        // Create ports sheet
        if (sweepDetails.ports && sweepDetails.ports.length > 0) {
            const portsData = sweepDetails.ports.map((port) => ({
                Port: port.port,
                'Hosts Available': port.available,
                'Response Rate':
                    ((port.available / sweepDetails.total_hosts) * 100).toFixed(2) + '%',
            }));
            const portsSheet = XLSX.utils.json_to_sheet(portsData);
            XLSX.utils.book_append_sheet(wb, portsSheet, 'Ports');
        }

        // Create hosts sheet with sorted data
        if (sweepDetails.hosts && sweepDetails.hosts.length > 0) {
            const hostsData = sweepDetails.hosts.map((host) => {
                const openPorts =
                    host.port_results
                        ?.filter((port) => port.available)
                        .map((port) => port.port)
                        .join(', ') || '';

                let icmpStatus = 'N/A';
                let responseTime = 'N/A';

                // Handle ICMP status and response time
                if (host.icmp_status) {
                    // Format ICMP status
                    icmpStatus =
                        host.icmp_status.packet_loss === 0
                            ? 'Responding'
                            : `${host.icmp_status.packet_loss}% Packet Loss`;

                    // Format response time if available
                    if (typeof host.icmp_status.round_trip === 'number') {
                        responseTime =
                            (host.icmp_status.round_trip / 1000000).toFixed(2) + 'ms';
                    }
                }

                return {
                    Host: host.host,
                    Status: host.available ? 'Online' : 'Offline',
                    'Open Ports': openPorts,
                    'ICMP Status': icmpStatus,
                    'Response Time': responseTime,
                    'First Seen': new Date(host.first_seen).toLocaleString(),
                    'Last Seen': new Date(host.last_seen).toLocaleString(),
                };
            });

            // Sort hosts by IP address
            hostsData.sort((a, b) => {
                const aMatch = a.Host.match(/(\d+)$/);
                const bMatch = b.Host.match(/(\d+)$/);
                if (aMatch && bMatch) {
                    return parseInt(aMatch[1]) - parseInt(bMatch[1]);
                }
                return a.Host.localeCompare(b.Host);
            });

            const hostsSheet = XLSX.utils.json_to_sheet(hostsData);
            XLSX.utils.book_append_sheet(wb, hostsSheet, 'Hosts');
        }

        // Auto-size columns for all sheets
        const sheets = ['Summary', 'Ports', 'Hosts'];
        sheets.forEach((sheet) => {
            if (wb.Sheets[sheet]) {
                const worksheet = wb.Sheets[sheet];
                const range = XLSX.utils.decode_range(worksheet['!ref']);

                for (let C = range.s.c; C <= range.e.c; ++C) {
                    let max_width = 0;

                    for (let R = range.s.r; R <= range.e.r; ++R) {
                        const cell_address = { c: C, r: R };
                        const cell_ref = XLSX.utils.encode_cell(cell_address);

                        if (worksheet[cell_ref]) {
                            const value = worksheet[cell_ref].v.toString();
                            max_width = Math.max(max_width, value.length);
                        }
                    }

                    worksheet['!cols'] = worksheet['!cols'] || [];
                    worksheet['!cols'][C] = { wch: max_width + 2 };
                }
            }
        });

        // Generate timestamp for filename
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, -5);

        // Save the file
        XLSX.writeFile(wb, `network-sweep-${timestamp}.xlsx`);
    };

    return (
        <button
            onClick={handleExport}
            className="flex items-center gap-2 px-4 py-2 rounded text-white
                 bg-blue-500 hover:bg-blue-600 transition-colors
                 dark:bg-blue-600 dark:hover:bg-blue-700"
        >
            <Download size={16} />
            Export Results
        </button>
    );
};

export default ExportButton;
