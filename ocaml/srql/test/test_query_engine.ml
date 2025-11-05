open Alcotest
module Column = Proton.Column

let translation_of qstr =
  let qspec = Srql_translator.Query_parser.parse qstr in
  match Srql_translator.Query_planner.plan_to_srql qspec with
  | None -> fail "planner returned None"
  | Some ast -> (
      match Srql_translator.Query_validator.validate ast with
      | Error msg -> fail msg
      | Ok () -> Srql_translator.Translator.translate_query ast)

let contains msg hay needle =
  let lhay = String.lowercase_ascii hay and lneedle = String.lowercase_ascii needle in
  let sub s sub =
    let ls = String.length s and lsub = String.length sub in
    let rec loop i =
      if i + lsub > ls then false else if String.sub s i lsub = sub then true else loop (i + 1)
    in
    loop 0
  in
  if not (sub lhay lneedle) then
    fail (Printf.sprintf "%s: expected to find '%s' in '%s'" msg needle hay)

let not_contains msg hay needle =
  let lhay = String.lowercase_ascii hay and lneedle = String.lowercase_ascii needle in
  let len_h = String.length lhay and len_n = String.length lneedle in
  let rec loop i =
    if i + len_n > len_h then false
    else if String.sub lhay i len_n = lneedle then true
    else loop (i + 1)
  in
  if loop 0 then fail (Printf.sprintf "%s: did not expect '%s' in '%s'" msg needle hay)

let test_devices_today () =
  let translation = translation_of "in:devices name:server01 time:today" in
  let sql = translation.sql in
  contains "from table" sql "from table(unified_devices)";
  contains "time today to_date" sql "to_date(";
  contains "time today func" sql ") = today()";
  contains "hostname mapping" sql "hostname = {{";
  contains "merged filter" sql "NOT has(map_keys(metadata), '_merged_into')";
  contains "deleted filter" sql "coalesce(metadata['_deleted'], '') != 'true'";
  check bool "hostname parameter present" true
    (List.exists (function _, Column.String "server01" -> true | _ -> false) translation.params)

let test_flows_topk_by () =
  let translation = translation_of "in:flows src:10.0.0.1 stats:\"topk(dst, 5)\"" in
  let sql = translation.sql in
  contains "group by dst" sql "group by dst_ip";
  contains "count alias" sql "count() AS cnt";
  contains "order by cnt" sql "order by cnt desc";
  contains "limit present" sql "limit 5";
  contains "src filter" sql "src_ip = {{";
  check bool "src placeholder value" true
    (List.exists (function _, Column.String "10.0.0.1" -> true | _ -> false) translation.params)

let test_validation_having_error () =
  let qspec =
    Srql_translator.Query_parser.parse
      "in:devices name:server stats:\"count()\" having:\"hostname>1\""
  in
  match Srql_translator.Query_planner.plan_to_srql qspec with
  | None -> fail "planner returned None"
  | Some ast -> (
      match Srql_translator.Query_validator.validate ast with
      | Ok () -> fail "expected validation error"
      | Error _ -> ())

let test_devices_ip_equality () =
  let translation = translation_of "in:devices ip:\"10.139.236.7\"" in
  let sql = translation.sql in
  contains "ip equality condition" sql "ip = {{";
  check bool "ip parameter present" true
    (List.exists
       (function _, Column.String value -> String.equal value "10.139.236.7" | _ -> false)
       translation.params)

let test_devices_ipaddress_alias () =
  let translation = translation_of "in:devices ipAddress:\"10.238.179.157\"" in
  let sql = translation.sql in
  contains "ipAddress alias maps to ip" sql "ip = {{";
  check bool "ipAddress parameter present" true
    (List.exists
       (function _, Column.String value -> String.equal value "10.238.179.157" | _ -> false)
       translation.params)

let test_devices_search_router () =
  let translation = translation_of "in:devices search:\"router-01\"" in
  let sql = translation.sql in
  contains "search includes hostname match" sql "hostname ILIKE {{";
  contains "search includes device_id match" sql "device_id ILIKE {{";
  contains "search includes poller match" sql "poller_id ILIKE {{";
  contains "search includes mac match" sql "mac ILIKE {{";
  contains "search includes ip wildcard" sql "ip ILIKE {{";
  not_contains "search excludes sys_descr" sql "sys_descr ILIKE {{";
  check bool "router wildcard param present" true
    (List.exists
       (function _, Column.String "%router-01%" -> true | _ -> false)
       translation.params)

let test_devices_search_ipv4 () =
  let translation = translation_of "in:devices search:\"10.139.236.7\"" in
  let sql = translation.sql in
  contains "search includes ip equality" sql "ip = {{";
  contains "search includes ip wildcard" sql "ip ILIKE {{";
  not_contains "search excludes observables_ip" sql "has(observables_ip, {{";
  check bool "ip equality param present" true
    (List.exists
       (function _, Column.String value -> String.equal value "10.139.236.7" | _ -> false)
       translation.params);
  check bool "ip wildcard param present" true
    (List.exists
       (function _, Column.String value -> String.equal value "%10.139.236.7%" | _ -> false)
       translation.params)

let test_devices_search_numeric_literal () =
  let translation = translation_of "in:devices search:\"10\"" in
  let sql = translation.sql in
  contains "numeric search uses wildcard" sql "ip ILIKE {{";
  not_contains "numeric search avoids raw column compare" sql "search =";
  check bool "numeric wildcard param present" true
    (List.exists
       (function _, Column.String value -> String.equal value "%10%" | _ -> false)
       translation.params)

let test_devices_collector_capabilities () =
  let translation =
    translation_of
      "in:devices collector_capabilities.has_collector:true \
       collector_capabilities.supports_icmp:true stats:\"count() as total\""
  in
  let sql = translation.sql in
  contains "collector has_collector expression" sql "has(map_keys(metadata), 'collector_agent_id')";
  contains "collector supports_icmp expression" sql
    "has(map_keys(metadata), '_last_icmp_update_at')";
  contains "has_collector predicate uses placeholder" sql
    "if(has(map_keys(metadata), 'collector_agent_id')";
  contains "stats included" sql "count() AS total";
  check bool "boolean parameters mapped to 1" true
    (List.exists
       (function
         | _, Column.Int32 v when v = 1l -> true
         | _, Column.Int64 v when v = 1L -> true
         | _ -> false)
       translation.params)

let test_sysmon_stats_argmax () =
  let translation =
    translation_of
      "in:cpu_metrics time:last_2h stats:\"argMax(agent_id, timestamp) as agent_id, \
       argMax(poller_id, timestamp) as poller_id, avg(usage_percent) as avg_cpu_usage by \
       device_id\""
  in
  let sql = translation.sql in
  contains "argmax preserved" sql "argMax(agent_id, timestamp)";
  contains "poller argmax" sql "argMax(poller_id, timestamp)";
  contains "avg usage present" sql "avg(usage_percent)";
  contains "group by device" sql "GROUP BY device_id";
  contains "time filter last_2h" sql "INTERVAL 2 HOUR"

let test_rperf_metrics_mapping () =
  let translation = translation_of "in:rperf_metrics metric_type:rperf time:last_1h" in
  let sql = translation.sql in
  contains "rperf metrics table" sql "from table(timeseries_metrics)";
  contains "metric_type filter" sql "metric_type = {{";
  contains "time filter last_1h" sql "INTERVAL 1 HOUR"

let suite =
  [
    ("devices today mapping", `Quick, test_devices_today);
    ("flows topk_by ranking", `Quick, test_flows_topk_by);
    ("having invalid reference", `Quick, test_validation_having_error);
    ("devices ip equality filter", `Quick, test_devices_ip_equality);
    ("devices ipAddress alias", `Quick, test_devices_ipaddress_alias);
    ("devices search wildcard fanout", `Quick, test_devices_search_router);
    ("devices search ipv4 equality", `Quick, test_devices_search_ipv4);
    ("devices search numeric literal", `Quick, test_devices_search_numeric_literal);
    ("devices collector capabilities mapping", `Quick, test_devices_collector_capabilities);
    ("sysmon stats argmax", `Quick, test_sysmon_stats_argmax);
    ("rperf metrics mapping", `Quick, test_rperf_metrics_mapping);
  ]

let () = Alcotest.run "query_engine" [ ("planner+translator", suite) ]

(* Additional tests for ASQ examples *)

let test_services_ports_timeframe () =
  let translation = translation_of "in:services port:(22,2222) timeFrame:\"7 Days\"" in
  let sql = translation.sql in
  contains "services table" sql "from table(services)";
  contains "port IN list" sql "port IN ({{";
  contains "7 days timeframe" sql "INTERVAL 7 DAY";
  check bool "22 present" true
    (List.exists (function _, Column.Int64 n -> n = 22L | _ -> false) translation.params);
  check bool "2222 present" true
    (List.exists (function _, Column.Int64 n -> n = 2222L | _ -> false) translation.params)

let test_devices_nested_services_and_type () =
  let translation =
    translation_of "in:devices services:(name:(facebook)) type:MRIs timeFrame:\"7 Days\""
  in
  let sql = translation.sql in
  contains "devices table" sql "from table(unified_devices)";
  contains "service name flattened" sql "services_name = {{";
  contains "MRIs type equality" sql "type = {{";
  check bool "facebook param" true
    (List.exists (function _, Column.String "facebook" -> true | _ -> false) translation.params);
  check bool "MRIs param" true
    (List.exists (function _, Column.String "MRIs" -> true | _ -> false) translation.params);
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let test_activity_connection_nested () =
  let q =
    "in:activity type:\"Connection Started\" connection:(from:(type:\"Mobile Phone\") \
     direction:\"From > To\" to:(boundary:Corporate tag:Managed)) timeFrame:\"7 Days\""
  in
  let translation = translation_of q in
  let sql = translation.sql in
  contains "events alias" sql "from table(events)";
  contains "nested flatten 1" sql "connection_from_type = {{";
  contains "nested flatten 2" sql "connection_direction = {{";
  contains "boundary->partition alias" sql "connection_to_partition = {{";
  let expect_string value =
    List.exists
      (function _, Column.String s -> String.equal s value | _ -> false)
      translation.params
  in
  check bool "mobile phone param" true (expect_string "Mobile Phone");
  check bool "direction param" true (expect_string "From > To");
  check bool "corporate param" true (expect_string "Corporate");
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let suite_asq =
  [
    ("services ports + timeframe", `Quick, test_services_ports_timeframe);
    ("devices services nested + type", `Quick, test_devices_nested_services_and_type);
    ("activity connection nested", `Quick, test_activity_connection_nested);
  ]

let () = Alcotest.run "asq_examples" [ ("examples", suite_asq) ]

(* Negation tests *)

let test_negation_list_devices () =
  let translation = translation_of "in:devices !model:(Hikvision,Zhejiang) timeFrame:\"7 Days\"" in
  let sql = translation.sql in
  contains "not in emitted" sql "NOT (model IN ({{";
  contains "7 days timeframe" sql "INTERVAL 7 DAY";
  check bool "Hikvision param" true
    (List.exists (function _, Column.String "Hikvision" -> true | _ -> false) translation.params);
  check bool "Zhejiang param" true
    (List.exists (function _, Column.String "Zhejiang" -> true | _ -> false) translation.params)

let test_negation_like_services () =
  let translation = translation_of "in:services !name:%ssh% timeFrame:\"7 Days\"" in
  let sql = translation.sql in
  contains "not like emitted" sql "NOT name ILIKE {{";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let suite_neg =
  [
    ("devices NOT IN list", `Quick, test_negation_list_devices);
    ("services NOT LIKE", `Quick, test_negation_like_services);
  ]

let () = Alcotest.run "negation_examples" [ ("negation", suite_neg) ]

(* More nested/alias/wildcard/timeframe tests *)

let test_devices_boundary_alias () =
  let translation = translation_of "in:devices boundary:Corporate" in
  let sql = translation.sql in
  contains "partition alias" sql "partition = {{";
  check bool "Corporate param" true
    (List.exists (function _, Column.String "Corporate" -> true | _ -> false) translation.params)

let test_services_like_positive () =
  let translation = translation_of "in:services name:%ssh%" in
  let sql = translation.sql in
  contains "like emitted" sql "name ILIKE {{";
  check bool "ssh pattern param" true
    (List.exists (function _, Column.String "%ssh%" -> true | _ -> false) translation.params)

let test_nested_negation_group_with_timeframe_hours () =
  let translation =
    translation_of
      "in:activity connection:(to:(!tag:Managed, boundary:Corporate)) timeFrame:\"12 Hours\""
  in
  let sql = translation.sql in
  contains "not tag managed" sql "NOT connection_to_tag = {{";
  contains "partition alias within group" sql "connection_to_partition = {{";
  check bool "Managed param" true
    (List.exists (function _, Column.String "Managed" -> true | _ -> false) translation.params);
  check bool "Corporate param" true
    (List.exists (function _, Column.String "Corporate" -> true | _ -> false) translation.params);
  contains "12 hours timeframe" sql "INTERVAL 12 HOUR"

let suite_more =
  [
    ("devices boundary->partition", `Quick, test_devices_boundary_alias);
    ("services LIKE positive", `Quick, test_services_like_positive);
    ("nested negation + timeframe hours", `Quick, test_nested_negation_group_with_timeframe_hours);
  ]

let () = Alcotest.run "asq_more" [ ("more", suite_more) ]

(* discovery_sources contains both 'sweep' and 'armis' *)

let test_devices_discovery_sources_both () =
  let translation =
    translation_of "in:devices discovery_sources:(sweep) discovery_sources:(armis)"
  in
  let sql = translation.sql in
  contains "has sweep" sql "has(discovery_sources, {{";
  contains "has armis" sql "has(discovery_sources, {{";
  check bool "sweep param" true
    (List.exists (function _, Column.String "sweep" -> true | _ -> false) translation.params);
  check bool "armis param" true
    (List.exists (function _, Column.String "armis" -> true | _ -> false) translation.params);
  contains "both AND" sql "AND"

let suite_arrays =
  [ ("devices discovery_sources both", `Quick, test_devices_discovery_sources_both) ]

let () = Alcotest.run "asq_arrays" [ ("arrays", suite_arrays) ]

(* Additional LIKE / NOT LIKE cases *)

let test_devices_like_hostname () =
  let translation = translation_of "in:devices hostname:%cam%" in
  let sql = translation.sql in
  contains "hostname LIKE" sql "hostname ILIKE {{";
  check bool "hostname pattern param" true
    (List.exists (function _, Column.String "%cam%" -> true | _ -> false) translation.params)

let test_devices_not_like_hostname () =
  let translation = translation_of "in:devices !hostname:%cam%" in
  let sql = translation.sql in
  contains "hostname NOT LIKE" sql "NOT hostname ILIKE {{";
  check bool "hostname not pattern param" true
    (List.exists (function _, Column.String "%cam%" -> true | _ -> false) translation.params)

let test_activity_like_nested_decision_host () =
  let translation = translation_of "in:activity decisionData:(host:(%ipinfo.%))" in
  let sql = translation.sql in
  contains "events table" sql "from table(events)";
  contains "nested LIKE" sql "decisionData_host ILIKE {{";
  check bool "decision host param" true
    (List.exists (function _, Column.String "%ipinfo.%" -> true | _ -> false) translation.params)

let test_activity_not_like_nested_decision_host () =
  let translation = translation_of "in:activity decisionData:(host:(!%ipinfo.%))" in
  let sql = translation.sql in
  contains "nested NOT LIKE" sql "NOT decisionData_host ILIKE {{";
  check bool "decision host not param" true
    (List.exists (function _, Column.String "%ipinfo.%" -> true | _ -> false) translation.params)

let suite_like =
  [
    ("devices LIKE hostname", `Quick, test_devices_like_hostname);
    ("devices NOT LIKE hostname", `Quick, test_devices_not_like_hostname);
    ("activity nested LIKE decisionData.host", `Quick, test_activity_like_nested_decision_host);
    ( "activity nested NOT LIKE decisionData.host",
      `Quick,
      test_activity_not_like_nested_decision_host );
  ]

let () = Alcotest.run "asq_like" [ ("like", suite_like) ]
