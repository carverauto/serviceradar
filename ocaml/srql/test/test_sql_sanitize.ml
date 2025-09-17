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

let contains_substring s sub =
  let len_s = String.length s and len_sub = String.length sub in
  let rec loop i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else loop (i + 1)
  in
  if len_sub = 0 then false else loop 0

let check_contains msg hay needle =
  if not (contains_substring hay needle) then
    fail (Printf.sprintf "%s: expected to find '%s' in '%s'" msg needle hay)

let expect_invalid_arg name f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> fail (name ^ ": expected Invalid_argument to be raised")

let test_escape_single_quote () =
  let translation = translation_of "in:events host:\"O'Reilly\"" in
  check_contains "placeholder present" translation.sql "host = {{";
  check bool "parameter captured" true
    (List.exists
       (function _, Column.String s -> String.equal s "O'Reilly" | _ -> false)
       translation.params)

let test_escape_injection_payload () =
  let payload = "a'); DROP STREAM devices; --" in
  let translation = translation_of (Printf.sprintf "in:events host:\"%s\"" payload) in
  check_contains "placeholder present" translation.sql "host = {{";
  check bool "payload captured as param" true
    (List.exists
       (function _, Column.String s -> String.equal s payload | _ -> false)
       translation.params)

let test_absolute_time_escape () =
  expect_invalid_arg "time injection" (fun () ->
      let qspec =
        Srql_translator.Query_parser.parse
          "in:events time:[2024-07-01T00:00:00Z,2024-07-02T00:00:00Z'); DROP STREAM logs; --]"
      in
      ignore (Srql_translator.Query_planner.plan_to_srql qspec))

let test_rejects_bad_alias () =
  expect_invalid_arg "alias" (fun () ->
      ignore
        (Srql_translator.Query_planner.parse_stats ~entity:"events" "sum(bytes) as total-bytes"))

let test_rejects_bad_stats_expression () =
  expect_invalid_arg "stats expr" (fun () ->
      ignore (Srql_translator.Query_planner.parse_stats ~entity:"events" "sum(bytes); DROP"))

let test_rejects_bad_field_name () =
  expect_invalid_arg "field" (fun () ->
      ignore (Srql_translator.Field_mapping.map_field_name ~entity:"events" "foo) OR 1=1 --"))

let alphabet =
  [|
    'a';
    'b';
    'c';
    'd';
    'e';
    'f';
    'g';
    'h';
    'i';
    'j';
    'k';
    'l';
    'm';
    'n';
    'o';
    'p';
    'q';
    'r';
    's';
    't';
    'u';
    'v';
    'w';
    'x';
    'y';
    'z';
    'A';
    'B';
    'C';
    'D';
    'E';
    'F';
    'G';
    'H';
    'I';
    'J';
    'K';
    'L';
    'M';
    'N';
    'O';
    'P';
    'Q';
    'R';
    'S';
    'T';
    'U';
    'V';
    'W';
    'X';
    'Y';
    'Z';
    '0';
    '1';
    '2';
    '3';
    '4';
    '5';
    '6';
    '7';
    '8';
    '9';
    '\'';
    ';';
    ':';
    ',';
    '.';
    ')';
    '(';
    '_';
    '-';
    ' ';
    '!';
    '@';
    '#';
    '$';
    '%';
    '&';
    '+';
    '=';
    '?';
    '[';
    ']';
    '{';
    '}';
    '^';
  |]

let random_payload () =
  let len = 1 + Random.int 24 in
  String.init len (fun _ -> alphabet.(Random.int (Array.length alphabet)))

let test_fuzz_string_escaping () =
  Random.init 0x5eed;
  for _ = 1 to 200 do
    let payload = random_payload () in
    try
      let translation = translation_of (Printf.sprintf "in:events host:\"%s\"" payload) in
      check_contains "placeholder present" translation.sql "{{";
      check bool "parameters captured" true (translation.params <> [])
    with Invalid_argument _ -> ()
  done

let () =
  Alcotest.run "sql_sanitize"
    [
      ( "escaping",
        [
          ("single quote", `Quick, test_escape_single_quote);
          ("payload injection", `Quick, test_escape_injection_payload);
          ("absolute time", `Quick, test_absolute_time_escape);
        ] );
      ( "rejections",
        [
          ("bad alias", `Quick, test_rejects_bad_alias);
          ("bad stats expression", `Quick, test_rejects_bad_stats_expression);
          ("bad field", `Quick, test_rejects_bad_field_name);
        ] );
      ("fuzz", [ ("string escaping", `Slow, test_fuzz_string_escaping) ]);
    ]
