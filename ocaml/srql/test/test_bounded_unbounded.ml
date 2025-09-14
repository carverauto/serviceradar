open Alcotest

let contains ~needle s =
  let ls = String.length s and ln = String.length needle in
  let rec loop i = if i + ln > ls then false else if String.sub s i ln = needle then true else loop (i+1) in
  loop 0

let mk_devices_conditions () =
  let open Srql_translator.Sql_ir in
  let c1 = Condition ("discovery_sources", ArrayContains, String "sweep") in
  let c2 = Condition ("discovery_sources", ArrayContains, String "armis") in
  And (c1, c2)

let test_bounded_wraps_table () =
  let open Srql_translator in
  let open Sql_ir in
  let q = {
    q_type = `Select;
    entity = "devices";
    conditions = Some (mk_devices_conditions ());
    limit = Some 10;
    select_fields = Some ["*"];
    order_by = None;
    group_by = None;
    having = None;
    latest = false;
  } in
  let sql = Translator.translate_query q in
  check bool "has table() wrapper" true (contains ~needle:" FROM table(unified_devices)" sql);
  check bool "has LIMIT 10" true (contains ~needle:" LIMIT 10" sql)

let test_unbounded_no_table_wrapper () =
  let open Srql_translator in
  let open Sql_ir in
  let q = {
    q_type = `Stream;
    entity = "devices";
    conditions = Some (mk_devices_conditions ());
    limit = None; (* streaming: no implicit limit here *)
    select_fields = Some ["*"];
    order_by = None;
    group_by = None;
    having = None;
    latest = false;
  } in
  let sql = Translator.translate_query q in
  check bool "no table() wrapper" false (contains ~needle:" FROM table(" sql);
  check bool "from unified_devices" true (contains ~needle:" FROM unified_devices" sql)

let () =
  run "srql_translator_bounded_unbounded" [
    ("translation", [
        test_case "bounded wraps table() and LIMIT" `Quick test_bounded_wraps_table;
        test_case "unbounded omits table() wrapper" `Quick test_unbounded_no_table_wrapper;
      ]);
  ]

