// Basic AGE graph types used by the web UI. These mirror the JSON shape
// returned by public.age_device_neighborhood in CNPG.

export interface AgeNode {
  id?: string;
  label?: string;
  properties?: Record<string, unknown>;
}

export interface AgeServiceEdge {
  service?: AgeNode;
  collector_id?: string | null;
  collector_owned?: boolean;
}

export interface DeviceGraphNeighborhood {
  device?: AgeNode | null;
  collectors?: AgeNode[];
  services?: AgeServiceEdge[];
  targets?: AgeNode[];
  interfaces?: AgeNode[];
  peer_interfaces?: AgeNode[];
  device_capabilities?: AgeNode[];
  service_capabilities?: AgeNode[];
}

export interface DeviceGraphResponse {
  result?: DeviceGraphNeighborhood | null;
}
