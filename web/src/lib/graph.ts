/*
 * Utility functions for working with AGE device graph responses.
 */
"use client";

import { fetchAPI } from "./client-api";
import type {
  AgeNode,
  AgeServiceEdge,
  DeviceGraphNeighborhood,
  DeviceGraphResponse,
} from "../types/deviceGraph";

const coerceBoolean = (value: boolean | undefined | null): boolean =>
  value === true;

export const nodeId = (node?: AgeNode | null): string => {
  if (!node) return "";
  const props = node.properties ?? {};
  const propId = typeof props["id"] === "string" ? props["id"] : undefined;
  if (propId) return propId;
  if (typeof node.id === "string") return node.id;
  return "";
};

export const nodeType = (node?: AgeNode | null): string => {
  if (!node) return "";
  const props = node.properties ?? {};
  const typeVal =
    typeof props["type"] === "string"
      ? props["type"]
      : typeof props["service_type"] === "string"
        ? props["service_type"]
        : undefined;
  if (typeVal) return typeVal;
  if (typeof node.label === "string") return node.label;
  return "";
};

export const capabilityLabel = (node?: AgeNode | null): string => {
  if (!node) return "";
  const props = node.properties ?? {};
  if (typeof props["type"] === "string") return props["type"];
  if (typeof node.label === "string") return node.label;
  return "";
};

type FetchGraphOptions = {
  collectorOwnedOnly?: boolean;
  includeTopology?: boolean;
};

export async function fetchDeviceGraph(
  deviceId: string,
  options: FetchGraphOptions = {},
): Promise<DeviceGraphNeighborhood | null> {
  const searchParams = new URLSearchParams();
  if (options.collectorOwnedOnly) {
    searchParams.set("collector_owned", "true");
  }
  if (options.includeTopology === false) {
    searchParams.set("include_topology", "false");
  }

  const url = [
    "/api/devices",
    encodeURIComponent(deviceId),
    "graph",
  ].join("/");
  const fullUrl =
    searchParams.size > 0 ? `${url}?${searchParams.toString()}` : url;

  const response = await fetchAPI<DeviceGraphResponse>(fullUrl);
  return (response?.result as DeviceGraphNeighborhood | null) ?? null;
}

export const collectorOwnedServices = (
  services: AgeServiceEdge[] | undefined,
): AgeServiceEdge[] =>
  (services ?? []).filter((svc) => coerceBoolean(svc.collector_owned));

export const targetServices = (
  services: AgeServiceEdge[] | undefined,
): AgeServiceEdge[] =>
  (services ?? []).filter((svc) => !coerceBoolean(svc.collector_owned));
