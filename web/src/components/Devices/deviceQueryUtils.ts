export const selectDevicesQuery = (incomingQuery: string, fallbackQuery: string): string => {
    const normalizedIncoming = incomingQuery.replace(/\s+/g, ' ').trim();
    if (normalizedIncoming.length === 0) {
        return fallbackQuery;
    }

    if (normalizedIncoming.toLowerCase().startsWith('in:devices')) {
        return normalizedIncoming;
    }

    return fallbackQuery;
};

export default selectDevicesQuery;
