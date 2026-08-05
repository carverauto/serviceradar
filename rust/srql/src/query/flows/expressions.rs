// Directionality derived from configured local CIDRs (fallback to persisted label when unresolved).
pub(in crate::query) const FLOW_DIRECTION_EXPR: &str = r#"CASE
  WHEN EXISTS (
    SELECT 1
    FROM netflow_local_cidrs c
    WHERE c.enabled
      AND (c.partition IS NULL OR c.partition = partition)
      AND (try_inet(NULLIF(src_endpoint_ip, '')) <<= c.cidr)
  )
  AND EXISTS (
    SELECT 1
    FROM netflow_local_cidrs c
    WHERE c.enabled
      AND (c.partition IS NULL OR c.partition = partition)
      AND (try_inet(NULLIF(dst_endpoint_ip, '')) <<= c.cidr)
  ) THEN 'bidirectional'
  WHEN EXISTS (
    SELECT 1
    FROM netflow_local_cidrs c
    WHERE c.enabled
      AND (c.partition IS NULL OR c.partition = partition)
      AND (try_inet(NULLIF(dst_endpoint_ip, '')) <<= c.cidr)
  ) THEN 'ingress'
  WHEN EXISTS (
    SELECT 1
    FROM netflow_local_cidrs c
    WHERE c.enabled
      AND (c.partition IS NULL OR c.partition = partition)
      AND (try_inet(NULLIF(src_endpoint_ip, '')) <<= c.cidr)
  ) THEN 'egress'
  ELSE COALESCE(direction_label, 'unknown')
END"#;

pub(in crate::query) const FLOW_PROTOCOL_GROUP_EXPR: &str =
    "CASE WHEN protocol_num = 6 THEN 'tcp' WHEN protocol_num = 17 THEN 'udp' ELSE 'other' END";

// Exporter/interface metadata projections for SRQL.
//
// These expressions are deliberately written without a table alias so they work in:
// - row queries (Diesel query builder)
// - stats queries (raw SQL with alias `f`)
// - downsample queries (raw SQL without alias)
//
// NOTE: cache tables live under `platform`, but SRQL assumes `search_path=platform,...`.
pub(in crate::query) const FLOW_SOURCE_EXPR: &str =
    "COALESCE(ocsf_payload->>'flow_source', 'Unknown')";

pub(in crate::query) const FLOW_EXPORTER_NAME_EXPR: &str = r#"
(SELECT ec.exporter_name
 FROM netflow_exporter_cache ec
 WHERE ec.sampler_address = sampler_address
 LIMIT 1)
"#;

pub(in crate::query) const FLOW_IN_IF_NAME_EXPR: &str = r#"
(SELECT ic.if_name
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(in crate::query) const FLOW_OUT_IF_NAME_EXPR: &str = r#"
(SELECT ic.if_name
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(in crate::query) const FLOW_IN_IF_SPEED_BPS_EXPR: &str = r#"
(SELECT ic.if_speed_bps
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(in crate::query) const FLOW_OUT_IF_SPEED_BPS_EXPR: &str = r#"
(SELECT ic.if_speed_bps
 FROM netflow_interface_cache ic
 WHERE ic.sampler_address = sampler_address
   AND ic.if_index = (CASE
     WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$'
     THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int
     ELSE NULL
   END)
 LIMIT 1)
"#;

pub(in crate::query) const FLOW_INPUT_SNMP_EXPR: &str = r#"(CASE
  WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$'
  THEN (ocsf_payload #>> '{connection_info,input_snmp}')::bigint
  ELSE NULL
END)"#;

pub(in crate::query) const FLOW_OUTPUT_SNMP_EXPR: &str = r#"(CASE
  WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$'
  THEN (ocsf_payload #>> '{connection_info,output_snmp}')::bigint
  ELSE NULL
END)"#;

pub(in crate::query) const FLOW_EXPORTER_NAME_GROUP_EXPR: &str = "COALESCE((SELECT ec.exporter_name FROM netflow_exporter_cache ec WHERE ec.sampler_address = sampler_address LIMIT 1), 'Unknown')";

pub(in crate::query) const FLOW_IN_IF_NAME_GROUP_EXPR: &str = "COALESCE((SELECT ic.if_name FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(in crate::query) const FLOW_OUT_IF_NAME_GROUP_EXPR: &str = "COALESCE((SELECT ic.if_name FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(in crate::query) const FLOW_IN_IF_SPEED_BPS_GROUP_EXPR: &str = "COALESCE((SELECT ic.if_speed_bps::text FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,input_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(in crate::query) const FLOW_OUT_IF_SPEED_BPS_GROUP_EXPR: &str = "COALESCE((SELECT ic.if_speed_bps::text FROM netflow_interface_cache ic WHERE ic.sampler_address = sampler_address AND ic.if_index = (CASE WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,output_snmp}')::int ELSE NULL END) LIMIT 1), 'Unknown')";

pub(in crate::query) const FLOW_CONVERSATION_A_IP_EXPR: &str = "CASE WHEN COALESCE(NULLIF(src_endpoint_ip, ''), 'Unknown') <= COALESCE(NULLIF(dst_endpoint_ip, ''), 'Unknown') THEN COALESCE(NULLIF(src_endpoint_ip, ''), 'Unknown') ELSE COALESCE(NULLIF(dst_endpoint_ip, ''), 'Unknown') END";

pub(in crate::query) const FLOW_CONVERSATION_B_IP_EXPR: &str = "CASE WHEN COALESCE(NULLIF(src_endpoint_ip, ''), 'Unknown') <= COALESCE(NULLIF(dst_endpoint_ip, ''), 'Unknown') THEN COALESCE(NULLIF(dst_endpoint_ip, ''), 'Unknown') ELSE COALESCE(NULLIF(src_endpoint_ip, ''), 'Unknown') END";

pub(in crate::query) const FLOW_INPUT_SNMP_GROUP_EXPR: &str = "COALESCE((CASE WHEN (ocsf_payload #>> '{connection_info,input_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,input_snmp}')::bigint ELSE NULL END)::text, 'Unknown')";

pub(in crate::query) const FLOW_OUTPUT_SNMP_GROUP_EXPR: &str = "COALESCE((CASE WHEN (ocsf_payload #>> '{connection_info,output_snmp}') ~ '^[0-9]+$' THEN (ocsf_payload #>> '{connection_info,output_snmp}')::bigint ELSE NULL END)::text, 'Unknown')";

pub(in crate::query) const FLOW_TCP_FLAGS_LABEL_EXPR: &str =
    "COALESCE(array_to_string(tcp_flags_labels, ','), 'Unknown')";

pub(in crate::query) const FLOW_DURATION_BUCKET_EXPR: &str = r#"CASE
  WHEN start_time IS NULL OR end_time IS NULL THEN 'unknown'
  WHEN EXTRACT(EPOCH FROM (end_time - start_time)) < 1 THEN '<1s'
  WHEN EXTRACT(EPOCH FROM (end_time - start_time)) < 10 THEN '1-10s'
  WHEN EXTRACT(EPOCH FROM (end_time - start_time)) < 60 THEN '10-60s'
  WHEN EXTRACT(EPOCH FROM (end_time - start_time)) < 300 THEN '1-5m'
  ELSE '>5m'
END"#;

// Application classification for flows.
//
// This is a derived label used by SRQL (`app:` filter, `by app` group-by, and downsample series).
// It is computed at query time using:
// - baseline protocol/port mapping
// - optional admin override rules in `netflow_app_classification_rules`
//
// NOTE: Table lives under `platform`, but SRQL assumes `search_path=platform,...`.
pub(in crate::query) const FLOW_APP_EXPR: &str = r#"
(SELECT
  COALESCE(override_rule.app_label, baseline.app_label, 'unknown')
  FROM LATERAL (
    SELECT
      CASE
        WHEN dst_endpoint_port IS NULL THEN NULL
        WHEN protocol_num = 6 AND dst_endpoint_port = 443 THEN 'https'
        WHEN protocol_num = 6 AND dst_endpoint_port = 80 THEN 'http'
        WHEN protocol_num = 6 AND dst_endpoint_port = 22 THEN 'ssh'
        WHEN dst_endpoint_port = 53 THEN 'dns'
        WHEN dst_endpoint_port = 123 THEN 'ntp'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (25, 465, 587) THEN 'smtp'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (143, 993) THEN 'imap'
        WHEN protocol_num = 6 AND dst_endpoint_port IN (110, 995) THEN 'pop3'
        WHEN protocol_num = 6 AND dst_endpoint_port = 3389 THEN 'rdp'
        WHEN protocol_num = 6 AND dst_endpoint_port = 5432 THEN 'postgres'
        WHEN protocol_num = 6 AND dst_endpoint_port = 3306 THEN 'mysql'
        WHEN protocol_num = 6 AND dst_endpoint_port = 6379 THEN 'redis'
        WHEN protocol_num = 6 AND dst_endpoint_port = 27017 THEN 'mongodb'
        WHEN protocol_num = 6 AND dst_endpoint_port = 9200 THEN 'elasticsearch'
        ELSE NULL
      END AS app_label,
      partition AS flow_partition,
      protocol_num AS flow_protocol_num,
      dst_endpoint_port AS flow_dst_port,
      src_endpoint_port AS flow_src_port,
      src_endpoint_ip AS flow_src_ip,
      dst_endpoint_ip AS flow_dst_ip
  ) baseline
  LEFT JOIN LATERAL (
    SELECT r.app_label
    FROM netflow_app_classification_rules r
    WHERE r.enabled
      AND (r.partition IS NULL OR r.partition = baseline.flow_partition)
      AND (r.protocol_num IS NULL OR r.protocol_num = baseline.flow_protocol_num)
      AND (r.dst_port IS NULL OR r.dst_port = baseline.flow_dst_port)
      AND (r.src_port IS NULL OR r.src_port = baseline.flow_src_port)
      AND (r.src_cidr IS NULL OR (try_inet(NULLIF(baseline.flow_src_ip, '')) <<= r.src_cidr))
      AND (r.dst_cidr IS NULL OR (try_inet(NULLIF(baseline.flow_dst_ip, '')) <<= r.dst_cidr))
    ORDER BY
      r.priority DESC,
      (
        (CASE WHEN r.protocol_num IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.dst_port IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.src_port IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.src_cidr IS NULL THEN 0 ELSE 1 END) +
        (CASE WHEN r.dst_cidr IS NULL THEN 0 ELSE 1 END)
      ) DESC,
      r.id ASC
    LIMIT 1
  ) override_rule ON TRUE)
"#;

pub(in crate::query) const ATTRIBUTED_FLOW_EVENT_TYPE_EXPR: &str =
    "ocsf_payload ->> 'event_type' = 'attributed_flow'";
pub(in crate::query) const ATTRIBUTED_FLOW_EVENT_TYPE_EXPR_ALIASED: &str =
    "f.ocsf_payload ->> 'event_type' = 'attributed_flow'";
pub(in crate::query) const ATTRIBUTION_STATUS_EXPR: &str = "CASE WHEN ocsf_payload -> 'attribution' ->> 'pid' IS NULL THEN 'unmatched' ELSE 'attributed' END";
pub(in crate::query) const ATTRIBUTION_STATUS_EXPR_ALIASED: &str = "CASE WHEN f.ocsf_payload -> 'attribution' ->> 'pid' IS NULL THEN 'unmatched' ELSE 'attributed' END";
pub(in crate::query) const ATTRIBUTION_PID_EXPR: &str = "ocsf_payload -> 'attribution' ->> 'pid'";
pub(in crate::query) const ATTRIBUTION_PID_EXPR_ALIASED: &str =
    "f.ocsf_payload -> 'attribution' ->> 'pid'";
pub(in crate::query) const ATTRIBUTION_UID_EXPR: &str = "ocsf_payload -> 'attribution' ->> 'uid'";
pub(in crate::query) const ATTRIBUTION_UID_EXPR_ALIASED: &str =
    "f.ocsf_payload -> 'attribution' ->> 'uid'";
pub(in crate::query) const ATTRIBUTION_COMM_EXPR: &str = "ocsf_payload -> 'attribution' ->> 'comm'";
pub(in crate::query) const ATTRIBUTION_COMM_EXPR_ALIASED: &str =
    "f.ocsf_payload -> 'attribution' ->> 'comm'";
pub(in crate::query) const ATTRIBUTION_CMDLINE_EXPR: &str =
    "ocsf_payload -> 'attribution' ->> 'redacted_cmdline'";
pub(in crate::query) const ATTRIBUTION_CMDLINE_EXPR_ALIASED: &str =
    "f.ocsf_payload -> 'attribution' ->> 'redacted_cmdline'";
pub(in crate::query) const ATTRIBUTION_CONTAINER_ID_EXPR: &str =
    "ocsf_payload -> 'attribution' ->> 'container_id'";
pub(in crate::query) const ATTRIBUTION_CONTAINER_ID_EXPR_ALIASED: &str =
    "f.ocsf_payload -> 'attribution' ->> 'container_id'";
pub(in crate::query) const ATTRIBUTION_AGENT_ID_EXPR: &str =
    "COALESCE(ocsf_payload ->> 'agent_id', ocsf_payload #>> '{metadata,agent_id}')";
pub(in crate::query) const ATTRIBUTION_AGENT_ID_EXPR_ALIASED: &str =
    "COALESCE(f.ocsf_payload ->> 'agent_id', f.ocsf_payload #>> '{metadata,agent_id}')";
pub(in crate::query) const ATTRIBUTION_POD_NAME_EXPR: &str =
    "ocsf_payload #>> '{attribution,workload_identity,pod_name}'";
pub(in crate::query) const ATTRIBUTION_POD_NAME_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,workload_identity,pod_name}'";
pub(in crate::query) const ATTRIBUTION_POD_NAMESPACE_EXPR: &str =
    "ocsf_payload #>> '{attribution,workload_identity,pod_namespace}'";
pub(in crate::query) const ATTRIBUTION_POD_NAMESPACE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,workload_identity,pod_namespace}'";
pub(in crate::query) const ATTRIBUTION_POD_UID_EXPR: &str =
    "ocsf_payload #>> '{attribution,workload_identity,pod_uid}'";
pub(in crate::query) const ATTRIBUTION_POD_UID_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,workload_identity,pod_uid}'";
pub(in crate::query) const ATTRIBUTION_CONTAINER_NAME_EXPR: &str =
    "ocsf_payload #>> '{attribution,workload_identity,container_name}'";
pub(in crate::query) const ATTRIBUTION_CONTAINER_NAME_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,workload_identity,container_name}'";
pub(in crate::query) const ATTRIBUTION_IMAGE_EXPR: &str = "COALESCE(ocsf_payload #>> '{attribution,workload_identity,image}', ocsf_payload #>> '{attribution,workload_identity,image_ref}')";
pub(in crate::query) const ATTRIBUTION_IMAGE_EXPR_ALIASED: &str = "COALESCE(f.ocsf_payload #>> '{attribution,workload_identity,image}', f.ocsf_payload #>> '{attribution,workload_identity,image_ref}')";
pub(in crate::query) const ATTRIBUTION_RUNTIME_SOURCE_EXPR: &str =
    "ocsf_payload #>> '{attribution,workload_identity,runtime_source}'";
pub(in crate::query) const ATTRIBUTION_RUNTIME_SOURCE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,workload_identity,runtime_source}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_SERVICE_EXPR: &str =
    "ocsf_payload #>> '{attribution,public_endpoint,service_name}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_SERVICE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,public_endpoint,service_name}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_GATEWAY_EXPR: &str =
    "ocsf_payload #>> '{attribution,public_endpoint,gateway_name}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_GATEWAY_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,public_endpoint,gateway_name}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_EXPOSURE_EXPR: &str =
    "ocsf_payload #>> '{attribution,public_endpoint,exposure_class}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_EXPOSURE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,public_endpoint,exposure_class}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_NAMESPACE_EXPR: &str =
    "ocsf_payload #>> '{attribution,public_endpoint,namespace}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_NAMESPACE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,public_endpoint,namespace}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_ROUTE_EXPR: &str =
    "ocsf_payload #>> '{attribution,public_endpoint,route_name}'";
pub(in crate::query) const ATTRIBUTION_PUBLIC_ENDPOINT_ROUTE_EXPR_ALIASED: &str =
    "f.ocsf_payload #>> '{attribution,public_endpoint,route_name}'";
