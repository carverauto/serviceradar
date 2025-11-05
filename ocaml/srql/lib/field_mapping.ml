open Sql_sanitize

let lc = String.lowercase_ascii
let trim = String.trim

let looks_like_expression s =
  let s = trim s in
  let len = String.length s in
  let rec loop i =
    if i >= len then false
    else match s.[i] with '(' | ')' | ' ' | '+' | '-' | '/' | '*' -> true | _ -> loop (i + 1)
  in
  loop 0

let map_field_name ~entity (field : string) : string =
  let field_trimmed = trim field in
  if field_trimmed = "*" then "*"
  else
    let field_lc = lc field_trimmed in
    let entity_lc = lc (trim entity) in
    let is_wrapped name s =
      let s' = lc (trim s) in
      let pref = name ^ "(" in
      let lp = String.length pref and ls = String.length s' in
      ls >= lp + 1 && String.sub s' 0 lp = pref && s'.[ls - 1] = ')'
    in
    if
      (String.contains field_trimmed '(' || String.contains field_trimmed ' ')
      && not (is_wrapped "date" field_trimmed)
    then invalid_arg (Printf.sprintf "Unsupported field expression '%s'" field_trimmed);
    let unwrap s =
      let s' = trim s in
      try
        let i = String.index s' '(' in
        let j = String.rindex s' ')' in
        String.sub s' (i + 1) (j - i - 1) |> trim
      with _ -> s'
    in
    let map_keys_expr = "map_keys(metadata)" in
    let array_exists_like pattern =
      Printf.sprintf "array_exists(k -> like(k, '%s'), %s)" pattern map_keys_expr
    in
    let wrap_bool cond = "(if(" ^ cond ^ ", 1, 0))" in
    let has_any keys =
      keys
      |> List.map (fun key -> "has(" ^ map_keys_expr ^ ", '" ^ key ^ "')")
      |> String.concat " OR "
    in
    let collector_capability_expr suffix =
      match suffix with
      | "has_collector" ->
          let explicit_keys =
            has_any
              [
                "collector_agent_id";
                "collector_poller_id";
                "_alias_last_seen_service_id";
                "_alias_collector_ip";
                "checker_service";
                "checker_service_type";
                "checker_service_id";
                "_last_icmp_update_at";
                "snmp_monitoring";
              ]
          in
          let collector_signals =
            [
              explicit_keys;
              array_exists_like "service_alias:%collector%";
              array_exists_like "service_alias:%checker%";
            ]
          in
          let condition =
            collector_signals
            |> List.filter (fun part -> String.trim part <> "")
            |> String.concat " OR "
          in
          wrap_bool condition
      | "supports_icmp" ->
          let condition = has_any [ "icmp_service_name"; "icmp_target"; "_last_icmp_update_at" ] in
          wrap_bool condition
      | "supports_snmp" -> wrap_bool (has_any [ "snmp_monitoring" ])
      | "supports_sysmon" ->
          let condition =
            [
              has_any [ "sysmon_monitoring"; "sysmon_service"; "sysmon_metric_source" ];
              array_exists_like "service_alias:%sysmon%";
            ]
            |> List.filter (fun part -> String.trim part <> "")
            |> String.concat " OR "
          in
          wrap_bool condition
      | _ -> String.map (fun c -> if c = '.' then '_' else c) suffix
    in
    let apply_entity_mapping f =
      match entity_lc with
      | "devices" -> (
          match f with
          | "name" | "host" | "device_name" -> "hostname"
          | "ip_address" | "ipaddress" | "device.ip" -> "ip"
          | "mac_address" | "macaddress" | "device.mac" -> "mac"
          | "uid" | "device.uid" -> "device_id"
          | "domain" | "device_domain" -> "device_domain"
          | "site" | "location" | "device_location" -> "device_location"
          | "os.name" | "device.os.name" -> "device_os_name"
          | "os.version" | "device.os.version" -> "device_os_version"
          | _ when String.contains f '.' ->
              let lf = lc f in
              if String.length lf > 3 && String.sub lf 0 3 = "os." then
                "device_os_" ^ String.sub lf 3 (String.length lf - 3)
              else if String.length lf > 12 && String.sub lf 0 12 = "observables." then
                "observables_" ^ String.sub lf 12 (String.length lf - 12)
              else
                let collector_prefix = "collector_capabilities." in
                let collector_prefix_len = String.length collector_prefix in
                if
                  String.length lf >= collector_prefix_len
                  && String.sub lf 0 collector_prefix_len = collector_prefix
                then
                  let suffix =
                    String.sub lf collector_prefix_len (String.length lf - collector_prefix_len)
                  in
                  collector_capability_expr suffix
                else if String.length lf > 9 && String.sub lf 0 9 = "metadata." then
                  "metadata['" ^ String.sub lf 9 (String.length lf - 9) ^ "']"
                else String.map (fun c -> if c = '.' then '_' else c) f
          | _ -> f)
      | "logs" -> (
          match f with
          | "severity" | "level" -> "severity_text"
          | "service" | "service.name" -> "service_name"
          | "endpoint.hostname" -> "endpoint_hostname"
          | _ when String.contains f '.' -> String.map (fun c -> if c = '.' then '_' else c) f
          | "trace" -> "trace_id"
          | "span" -> "span_id"
          | _ -> f)
      | "flows" | "connections" -> (
          match f with
          | "src" -> "src_ip"
          | "dst" -> "dst_ip"
          | "sport" -> "src_port"
          | "dport" -> "dst_port"
          | "src_endpoint.ip" -> "src_ip"
          | "src_endpoint.port" -> "src_port"
          | "dst_endpoint.ip" -> "dst_ip"
          | "dst_endpoint.port" -> "dst_port"
          | "traffic.bytes_in" -> "bytes_in"
          | "traffic.bytes_out" -> "bytes_out"
          | "traffic.packets_in" -> "packets_in"
          | "traffic.packets_out" -> "packets_out"
          | _ when String.contains f '.' -> String.map (fun c -> if c = '.' then '_' else c) f
          | "src_ip" | "dst_ip" | "src_port" | "dst_port" | "protocol" | "bytes" | "bytes_in"
          | "bytes_out" | "packets" | "packets_in" | "packets_out" | "direction" ->
              f
          | _ -> f)
      | "events" -> (
          match f with
          | _ when String.contains f '.' -> String.map (fun c -> if c = '.' then '_' else c) f
          | _ -> f)
      | "otel_traces" -> (
          match f with
          | "trace" -> "trace_id"
          | "span" -> "span_id"
          | "service" -> "service_name"
          | "name" -> "name"
          | "kind" -> "kind"
          | "start" -> "start_time_unix_nano"
          | "end" -> "end_time_unix_nano"
          | "duration_ms" -> "(end_time_unix_nano - start_time_unix_nano) / 1e6"
          | _ -> f)
      | "otel_metrics" -> (
          match f with
          | "trace" -> "trace_id"
          | "span" -> "span_id"
          | "service" -> "service_name"
          | "route" -> "http_route"
          | "method" -> "http_method"
          | "status" -> "http_status_code"
          | _ -> f)
      | "otel_trace_summaries" -> (
          match f with
          | "trace" -> "trace_id"
          | "service" -> "root_service_name"
          | "duration_ms" -> "duration_ms"
          | "status" -> "status_code"
          | "span_count" -> "span_count"
          | "errors" -> "error_count"
          | "start" -> "start_time_unix_nano"
          | "end" -> "end_time_unix_nano"
          | "root_span" -> "root_span_name"
          | _ -> f)
      | "otel_spans_enriched" -> (
          match f with
          | "trace" -> "trace_id"
          | "span" -> "span_id"
          | "service" -> "service_name"
          | "name" -> "name"
          | "kind" -> "kind"
          | "duration_ms" -> "duration_ms"
          | "is_root" -> "is_root"
          | "parent" -> "parent_span_id"
          | "start" -> "start_time_unix_nano"
          | "end" -> "end_time_unix_nano"
          | _ -> f)
      | "otel_root_spans" -> (
          match f with
          | "trace" -> "trace_id"
          | "span" -> "root_span_id"
          | "name" -> "root_span_name"
          | "kind" -> "root_kind"
          | "service" -> "root_service"
          | _ -> f)
      | "pollers" -> ( match f with "timestamp" -> "last_seen" | _ -> f)
      | _ -> f
    in
    let mapped =
      if is_wrapped "date" field_lc then
        let inner = unwrap field_lc |> apply_entity_mapping in
        "to_date(" ^ inner ^ ")"
      else apply_entity_mapping field_lc
    in
    if looks_like_expression mapped then (
      ensure_safe_expression ~context:"computed expression" mapped;
      mapped)
    else ensure_safe_identifier ~context:("field " ^ field_trimmed) mapped
