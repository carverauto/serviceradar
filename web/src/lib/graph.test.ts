import { describe, expect, it } from "vitest";
import {
  capabilityLabel,
  collectorOwnedServices,
  nodeId,
  nodeType,
  targetServices,
} from "./graph";
import type { AgeNode, AgeServiceEdge } from "../types/deviceGraph";

describe("graph helpers", () => {
  it("prefers properties.id when extracting nodeId", () => {
    const node: AgeNode = {
      id: "fallback",
      properties: {
        id: "primary-id",
      },
    };
    expect(nodeId(node)).toBe("primary-id");
  });

  it("falls back to node.id when properties.id is missing", () => {
    const node: AgeNode = { id: "node-id" };
    expect(nodeId(node)).toBe("node-id");
  });

  it("extracts nodeType from properties.type or label", () => {
    const nodeWithType: AgeNode = {
      properties: { type: "collector" },
    };
    const nodeWithLabel: AgeNode = { label: "Service" };

    expect(nodeType(nodeWithType)).toBe("collector");
    expect(nodeType(nodeWithLabel)).toBe("Service");
  });

  it("returns capability label from properties.type", () => {
    const node: AgeNode = { properties: { type: "snmp" } };
    expect(capabilityLabel(node)).toBe("snmp");
  });

  it("filters collector-owned and target services correctly", () => {
    const services: AgeServiceEdge[] = [
      { collector_owned: true, service: { properties: { id: "svc-1" } } },
      { collector_owned: false, service: { properties: { id: "svc-2" } } },
      { service: { properties: { id: "svc-3" } } },
    ];

    expect(collectorOwnedServices(services).map((s) => nodeId(s.service))).toEqual([
      "svc-1",
    ]);
    expect(targetServices(services).map((s) => nodeId(s.service))).toEqual([
      "svc-2",
      "svc-3",
    ]);
  });
});
