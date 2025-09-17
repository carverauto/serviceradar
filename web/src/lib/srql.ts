/**
 * Escape characters that have special meaning in SRQL string filters.
 * Currently SRQL treats double quotes as string delimiters and backslashes as escape characters.
 */
export const escapeSrqlValue = (value: string | number | boolean): string =>
    String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
