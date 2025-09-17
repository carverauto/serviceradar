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
    let apply_entity_mapping f =
      match entity_lc with
      | "devices" -> (
          match f with
          | "name" | "host" | "device_name" -> "hostname"
          | "ip_address" | "device.ip" -> "ip"
          | "mac_address" | "device.mac" -> "mac"
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
