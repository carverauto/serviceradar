/**
 * Format numbers to human-readable strings with abbreviations
 * @param num - The number to format
 * @returns Formatted string (e.g., 1500 -> "1.5k", 25000 -> "25k")
 */
export const formatNumber = (num: number): string => {
    if (num >= 1000000) {
        return (num / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
    }
    if (num >= 1000) {
        return (num / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
    }
    return num.toString();
};

/**
 * Format duration in milliseconds to human-readable string
 * @param ms - Duration in milliseconds
 * @returns Formatted string (e.g., 1500 -> "1.50s", 150 -> "150ms")
 */
export const formatDuration = (ms: number): string => {
    if (ms >= 1000) {
        return (ms / 1000).toFixed(2) + 's';
    }
    return Math.round(ms) + 'ms';
};

/**
 * Format percentage values
 * @param value - Decimal value (e.g., 0.15 for 15%)
 * @returns Formatted percentage string (e.g., "15.0%")
 */
export const formatPercentage = (value: number): string => {
    return (value * 100).toFixed(1) + '%';
};