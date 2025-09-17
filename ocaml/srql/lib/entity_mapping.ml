(* ServiceRadar entity to table name mappings *)

type entity_config = { table_name : string; timestamp_field : string }

let entity_mappings =
  [
    ("devices", { table_name = "unified_devices"; timestamp_field = "last_seen" });
    ("flows", { table_name = "netflow_metrics"; timestamp_field = "timestamp" });
    ("interfaces", { table_name = "discovered_interfaces"; timestamp_field = "last_seen" });
    ("sweep_results", { table_name = "unified_devices"; timestamp_field = "timestamp" });
    ("traps", { table_name = "traps"; timestamp_field = "timestamp" });
    ("connections", { table_name = "connections"; timestamp_field = "timestamp" });
    ("logs", { table_name = "logs"; timestamp_field = "timestamp" });
    ("services", { table_name = "services"; timestamp_field = "timestamp" });
    ("device_updates", { table_name = "device_updates"; timestamp_field = "timestamp" });
    ("icmp_results", { table_name = "icmp_results"; timestamp_field = "timestamp" });
    ("snmp_results", { table_name = "timeseries_metrics"; timestamp_field = "timestamp" });
    ("events", { table_name = "events"; timestamp_field = "event_timestamp" });
    ("pollers", { table_name = "pollers"; timestamp_field = "last_seen" });
    ("cpu_metrics", { table_name = "cpu_metrics"; timestamp_field = "timestamp" });
    ("disk_metrics", { table_name = "disk_metrics"; timestamp_field = "timestamp" });
    ("memory_metrics", { table_name = "memory_metrics"; timestamp_field = "timestamp" });
    ("process_metrics", { table_name = "process_metrics"; timestamp_field = "timestamp" });
    ("snmp_metrics", { table_name = "timeseries_metrics"; timestamp_field = "timestamp" });
    ("otel_traces", { table_name = "otel_traces"; timestamp_field = "timestamp" });
    ("otel_metrics", { table_name = "otel_metrics"; timestamp_field = "timestamp" });
    ( "otel_trace_summaries",
      { table_name = "otel_trace_summaries_final"; timestamp_field = "timestamp" } );
    ("otel_spans_enriched", { table_name = "otel_spans_enriched"; timestamp_field = "timestamp" });
    ("otel_root_spans", { table_name = "otel_root_spans"; timestamp_field = "trace_id" });
  ]

let entity_map =
  List.fold_left
    (fun acc (entity, config) -> (String.lowercase_ascii entity, config) :: acc)
    [] entity_mappings

(* Get the actual table name for an entity *)
let get_table_name entity =
  let entity_lower = String.lowercase_ascii entity in
  try
    let config = List.assoc entity_lower entity_map in
    config.table_name
  with Not_found -> entity (* fallback to entity name if not mapped *)

(* Get the timestamp field for an entity *)
let get_timestamp_field entity =
  let entity_lower = String.lowercase_ascii entity in
  try
    let config = List.assoc entity_lower entity_map in
    config.timestamp_field
  with Not_found -> "timestamp" (* default timestamp field *)

(* Check if an entity needs default filters *)
let needs_default_discovery_filter entity =
  let entity_lower = String.lowercase_ascii entity in
  entity_lower = "device_updates" || entity_lower = "sweep_results"

let needs_snmp_filter entity =
  let entity_lower = String.lowercase_ascii entity in
  entity_lower = "snmp_results" || entity_lower = "snmp_metrics"

(* Primary key mapping for LATEST on non-versioned_kv streams *)
let primary_key_map : (string * string) list =
  [
    ("interfaces", "device_ip, ifIndex");
    ("pollers", "poller_id");
    ("cpu_metrics", "device_id, core_id");
    ("disk_metrics", "device_id, mount_point");
    ("memory_metrics", "device_id");
    ("process_metrics", "device_id, pid");
    ("flows", "flow_id");
  ]

let get_primary_key entity : string option =
  let e = String.lowercase_ascii entity in
  match List.assoc_opt e primary_key_map with Some k -> Some k | None -> None
