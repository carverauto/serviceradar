/**
 * Helpers for classifying device IDs and service/device relationships.
 */
const SERVICE_DEVICE_REGEX = /^serviceradar:([^:]+):(.+)$/i;

export const parseServiceDeviceId = (
  deviceId: string,
): { serviceType: string; serviceId: string } | null => {
  const match = SERVICE_DEVICE_REGEX.exec(deviceId.trim());
  if (!match) return null;

  const serviceType = match[1]?.toLowerCase() ?? "";
  const serviceId = match[2] ?? "";
  if (!serviceType || !serviceId) {
    return null;
  }

  return { serviceType, serviceId };
};

export const collectorServiceType = (
  deviceId: string,
  declaredType?: string | null,
): string | null => {
  const normalizedDeclared = declaredType?.trim().toLowerCase() ?? "";
  const parsed = parseServiceDeviceId(deviceId);
  if (!parsed) {
    return null;
  }

  const serviceType = normalizedDeclared || parsed.serviceType;
  if (!serviceType) {
    return null;
  }

  if (serviceType === "agent" || serviceType === "poller") {
    return null;
  }

  return serviceType;
};

export const isCollectorServiceDevice = (
  deviceId: string,
  declaredType?: string | null,
): boolean => collectorServiceType(deviceId, declaredType) !== null;
