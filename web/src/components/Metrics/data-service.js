// data-service.js

// Generate sample time series data
const generateTimeSeries = (baseValue, variance, count) => {
    const now = new Date();
    const data = [];

    for (let i = count - 1; i >= 0; i--) {
        const time = new Date(now - (i * (60 * 1000))); // Create data points for past minutes
        const value = baseValue + (Math.random() * variance * 2) - variance;

        data.push({
            timestamp: time.toISOString(),
            formattedTime: time.toLocaleTimeString(),
            value: Math.max(0, parseFloat(value.toFixed(1)))
        });
    }

    return data;
};

// Calculate percentage change between two values
const calculatePercentageChange = (current, previous) => {
    if (previous === 0) return 0;
    return ((current - previous) / previous) * 100;
};

// Sample data fetching function - replace with your actual API call
export const fetchEnvironmentData = async (pollerId, timeRange = '1h') => {
    // In a real implementation, this would call your SNMP or agent API
    // You'd replace this with actual API calls to your backend services

    return new Promise((resolve) => {
        // Simulate API call delay
        setTimeout(() => {
            // Points to generate based on time range
            let pointCount = 60; // Default to 60 points (1 hour)

            if (timeRange === '6h') pointCount = 360;
            else if (timeRange === '24h') pointCount = 1440;

            // Create sample data for all metrics
            const temperature = {
                current: 42.5,
                warning: 45,
                critical: 65,
                data: generateTimeSeries(42.5, 5, pointCount),
                unit: '°C',
                min: 0,
                max: 100
            };

            const cpu = {
                current: 35.2,
                warning: 70,
                critical: 90,
                data: generateTimeSeries(35, 15, pointCount),
                unit: '%',
                min: 0,
                max: 100,
                cores: [
                    { name: 'Core 1', value: 42 },
                    { name: 'Core 2', value: 38 },
                    { name: 'Core 3', value: 25 },
                    { name: 'Core 4', value: 36 }
                ]
            };

            const memory = {
                current: 65.7,
                warning: 85,
                critical: 95,
                total: 16, // GB
                used: 10.5,
                data: generateTimeSeries(65, 10, pointCount),
                unit: '%',
                min: 0,
                max: 100
            };

            const filesystem = {
                drives: [
                    { name: '/', used: 210, size: 500, usedPercent: 42, warning: 75, critical: 90 },
                    { name: '/var', used: 120, size: 200, usedPercent: 60, warning: 75, critical: 90 },
                    { name: '/home', used: 150, size: 750, usedPercent: 20, warning: 75, critical: 90 }
                ],
                data: generateTimeSeries(35, 5, pointCount), // Overall filesystem trend
                unit: '%',
                warning: 75,
                critical: 90,
                min: 0,
                max: 100
            };

            // Calculate change rates
            if (temperature.data.length >= 2) {
                const latest = temperature.data[temperature.data.length - 1].value;
                const previous = temperature.data[temperature.data.length - 2].value;
                temperature.change = calculatePercentageChange(latest, previous);
            }

            if (cpu.data.length >= 2) {
                const latest = cpu.data[cpu.data.length - 1].value;
                const previous = cpu.data[cpu.data.length - 2].value;
                cpu.change = calculatePercentageChange(latest, previous);
            }

            if (memory.data.length >= 2) {
                const latest = memory.data[memory.data.length - 1].value;
                const previous = memory.data[memory.data.length - 2].value;
                memory.change = calculatePercentageChange(latest, previous);
            }

            const result = {
                temperature,
                cpu,
                memory,
                filesystem
            };

            resolve(result);
        }, 500);
    });
};

// Process multiple datasets for a combined chart
export const getCombinedChartData = (data) => {
    if (!data) return [];

    // Map all metrics to a common timestamp
    const combinedData = [];
    const keys = ['temperature', 'cpu', 'memory', 'filesystem'];

    // For simplicity, use the timestamps from temperature data
    if (data.temperature && data.temperature.data) {
        const tempData = data.temperature.data;

        tempData.forEach((point, index) => {
            const dataPoint = {
                timestamp: point.timestamp,
                formattedTime: point.formattedTime
            };

            // Add data from each metric
            keys.forEach(key => {
                if (data[key] && data[key].data && data[key].data[index]) {
                    dataPoint[key] = data[key].data[index].value;
                }
            });

            combinedData.push(dataPoint);
        });
    }

    return combinedData;
};