// Types for identity reconciliation UI (sightings, events, manual actions)

export interface NetworkSighting {
  sighting_id: string;
  partition: string;
  ip: string;
  subnet_id?: string | null;
  source: string;
  status: string;
  first_seen: string;
  last_seen: string;
  ttl_expires_at?: string | null;
  fingerprint_id?: string | null;
  metadata?: Record<string, string>;
  promotion?: SightingPromotionStatus;
}

export interface SightingEvent {
  event_id?: string;
  sighting_id: string;
  device_id?: string;
  event_type: string;
  actor: string;
  details?: Record<string, string>;
  created_at: string;
}

export interface IdentityConfigMeta {
  enabled?: boolean;
  sightings_only_mode?: boolean;
  promotion?: {
    enabled?: boolean;
    shadow_mode?: boolean;
    min_persistence?: string;
    require_hostname?: boolean;
    require_fingerprint?: boolean;
  };
}

export interface SightingPromotionStatus {
  meets_policy?: boolean;
  eligible?: boolean;
  shadow_mode?: boolean;
  blockers?: string[];
  satisfied?: string[];
  next_eligible_at?: string | null;
}

export interface SightingsResponse {
  items: NetworkSighting[];
  total?: number;
  limit?: number;
  offset?: number;
  identity?: IdentityConfigMeta;
}

export interface SightingEventsResponse {
  items: SightingEvent[];
}

export interface SubnetPolicy {
  subnet_id: string;
  cidr: string;
  classification: string;
  promotion_rules?: Record<string, unknown>;
  reaper_profile: string;
  allow_ip_as_id: boolean;
  created_at: string;
  updated_at: string;
}

export interface MergeAuditEvent {
  event_id: string;
  from_device_id: string;
  to_device_id: string;
  reason?: string;
  confidence_score?: number;
  source?: string;
  details?: Record<string, string>;
  created_at: string;
}

export interface SubnetPoliciesResponse {
  items: SubnetPolicy[];
}

export interface MergeAuditResponse {
  items: MergeAuditEvent[];
}
