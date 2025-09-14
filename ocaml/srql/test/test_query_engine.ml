open Alcotest

let sql_of qstr =
  let qspec = Srql_translator.Query_parser.parse qstr in
  match Srql_translator.Query_planner.plan_to_srql qspec with
  | None -> fail "planner returned None"
  | Some ast ->
      (match Srql_translator.Query_validator.validate ast with
       | Error msg -> fail msg
       | Ok () -> Srql_translator.Translator.translate_query ast)

let contains msg hay needle =
  let lhay = String.lowercase_ascii hay and lneedle = String.lowercase_ascii needle in
  let sub s sub =
    let ls = String.length s and lsub = String.length sub in
    let rec loop i = if i + lsub > ls then false else if String.sub s i lsub = sub then true else loop (i+1) in
    loop 0
  in
  if not (sub lhay lneedle) then
    fail (Printf.sprintf "%s: expected to find '%s' in '%s'" msg needle hay)

let test_devices_today () =
  let sql = sql_of "in:devices name:server01 time:today" in
  contains "from table" sql "from unified_devices";
  contains "time today to_date" sql "to_date(";
  contains "time today func" sql ") = today()";
  contains "hostname mapping" sql "hostname = 'server01'"

let test_flows_topk_by () =
  let sql = sql_of "in:flows src:10.0.0.1 stats:\"topk(dst, 5)\"" in
  contains "group by dst" sql "group by dst_ip";
  contains "count alias" sql "count() AS cnt";
  contains "order by cnt" sql "order by cnt desc";
  contains "limit present" sql "limit 5";
  contains "src filter" sql "src_ip = '10.0.0.1'"

let test_validation_having_error () =
  let qspec = Srql_translator.Query_parser.parse "in:devices name:server stats:\"count()\" having:\"hostname>1\"" in
  match Srql_translator.Query_planner.plan_to_srql qspec with
  | None -> fail "planner returned None"
  | Some ast ->
      match Srql_translator.Query_validator.validate ast with
      | Ok () -> fail "expected validation error"
      | Error _ -> ()

let suite = [
  "devices today mapping", `Quick, test_devices_today;
  "flows topk_by ranking", `Quick, test_flows_topk_by;
  "having invalid reference", `Quick, test_validation_having_error;
]

let () =
  Alcotest.run "query_engine" [ ("planner+translator", suite) ]

(* Additional tests for ASQ examples *)

let test_services_ports_timeframe () =
  let sql = sql_of "in:services port:(22,2222) timeFrame:\"7 Days\"" in
  contains "services table" sql "from services";
  contains "port IN list" sql "port IN (22, 2222)";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let test_devices_nested_services_and_type () =
  let sql = sql_of "in:devices services:(name:(facebook)) type:MRIs timeFrame:\"7 Days\"" in
  contains "devices table" sql "from unified_devices";
  contains "service name flattened" sql "services_name = 'facebook'";
  contains "MRIs type equality" sql "type = 'MRIs'";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let test_activity_connection_nested () =
  let q = "in:activity type:\"Connection Started\" connection:(from:(type:\"Mobile Phone\") direction:\"From > To\" to:(boundary:Corporate tag:Managed)) timeFrame:\"7 Days\"" in
  let sql = sql_of q in
  contains "events alias" sql "from events";
  contains "nested flatten 1" sql "connection_from_type = 'Mobile Phone'";
  contains "nested flatten 2" sql "connection_direction = 'From > To'";
  contains "boundary->partition alias" sql "connection_to_partition = 'Corporate'";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let suite_asq = [
  "services ports + timeframe", `Quick, test_services_ports_timeframe;
  "devices services nested + type", `Quick, test_devices_nested_services_and_type;
  "activity connection nested", `Quick, test_activity_connection_nested;
]

let () =
  Alcotest.run "asq_examples" [ ("examples", suite_asq) ]

(* Negation tests *)

let test_negation_list_devices () =
  let sql = sql_of "in:devices !model:(Hikvision,Zhejiang) timeFrame:\"7 Days\"" in
  contains "not in emitted" sql "NOT (model IN ('Hikvision', 'Zhejiang'))";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let test_negation_like_services () =
  let sql = sql_of "in:services !name:%ssh% timeFrame:\"7 Days\"" in
  contains "not like emitted" sql "NOT name LIKE '%ssh%'";
  contains "7 days timeframe" sql "INTERVAL 7 DAY"

let suite_neg = [
  "devices NOT IN list", `Quick, test_negation_list_devices;
  "services NOT LIKE", `Quick, test_negation_like_services;
]

let () =
  Alcotest.run "negation_examples" [ ("negation", suite_neg) ]

(* More nested/alias/wildcard/timeframe tests *)

let test_devices_boundary_alias () =
  let sql = sql_of "in:devices boundary:Corporate" in
  contains "partition alias" sql "partition = 'Corporate'"

let test_services_like_positive () =
  let sql = sql_of "in:services name:%ssh%" in
  contains "like emitted" sql "name LIKE '%ssh%'"

let test_nested_negation_group_with_timeframe_hours () =
  let sql = sql_of "in:activity connection:(to:(!tag:Managed, boundary:Corporate)) timeFrame:\"12 Hours\"" in
  contains "not tag managed" sql "NOT connection_to_tag = 'Managed'";
  contains "partition alias within group" sql "connection_to_partition = 'Corporate'";
  contains "12 hours timeframe" sql "INTERVAL 12 HOUR"

let suite_more = [
  "devices boundary->partition", `Quick, test_devices_boundary_alias;
  "services LIKE positive", `Quick, test_services_like_positive;
  "nested negation + timeframe hours", `Quick, test_nested_negation_group_with_timeframe_hours;
]

let () =
  Alcotest.run "asq_more" [ ("more", suite_more) ]

(* discovery_sources contains both 'sweep' and 'armis' *)

let test_devices_discovery_sources_both () =
  let sql = sql_of "in:devices discovery_sources:(sweep) discovery_sources:(armis)" in
  contains "has sweep" sql "has(discovery_sources, 'sweep')";
  contains "has armis" sql "has(discovery_sources, 'armis')";
  contains "both AND" sql "AND"

let suite_arrays = [
  "devices discovery_sources both", `Quick, test_devices_discovery_sources_both;
]

let () =
  Alcotest.run "asq_arrays" [ ("arrays", suite_arrays) ]

(* Additional LIKE / NOT LIKE cases *)

let test_devices_like_hostname () =
  let sql = sql_of "in:devices hostname:%cam%" in
  contains "hostname LIKE" sql "hostname LIKE '%cam%'"

let test_devices_not_like_hostname () =
  let sql = sql_of "in:devices !hostname:%cam%" in
  contains "hostname NOT LIKE" sql "NOT hostname LIKE '%cam%'"

let test_activity_like_nested_decision_host () =
  let sql = sql_of "in:activity decisionData:(host:(%ipinfo.%))" in
  contains "events table" sql "from events";
  contains "nested LIKE" sql "decisionData_host LIKE '%ipinfo.%'"

let test_activity_not_like_nested_decision_host () =
  let sql = sql_of "in:activity decisionData:(host:(!%ipinfo.%))" in
  contains "nested NOT LIKE" sql "NOT decisionData_host LIKE '%ipinfo.%'"

let suite_like = [
  "devices LIKE hostname", `Quick, test_devices_like_hostname;
  "devices NOT LIKE hostname", `Quick, test_devices_not_like_hostname;
  "activity nested LIKE decisionData.host", `Quick, test_activity_like_nested_decision_host;
  "activity nested NOT LIKE decisionData.host", `Quick, test_activity_not_like_nested_decision_host;
]

let () =
  Alcotest.run "asq_like" [ ("like", suite_like) ]
