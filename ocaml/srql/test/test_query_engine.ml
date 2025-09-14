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
