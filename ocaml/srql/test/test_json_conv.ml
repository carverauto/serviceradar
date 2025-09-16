open Alcotest

let to_json rows cols = Srql_translator.Json_conv.rows_to_json (rows, cols)

let test_uint64_string () =
  let cols = [ ("u64", "UInt64") ] in
  let rows = [ [ Proton.Column.UInt64 9007199254740993L ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("u64", `Intlit s) ] ] -> check string "u64-string" "9007199254740993" s
  | _ -> fail "Expected u64 as Intlit string"

let test_int64_string () =
  let cols = [ ("i64", "Int64") ] in
  let rows = [ [ Proton.Column.Int64 9223372036854775807L ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("i64", `Intlit s) ] ] -> check string "i64-string" "9223372036854775807" s
  | _ -> fail "Expected i64 as Intlit string"

let test_uint32_number () =
  let cols = [ ("u32", "UInt32") ] in
  let rows = [ [ Proton.Column.UInt32 42l ] ] in
  let j = to_json rows cols in
  match j with `List [ `Assoc [ ("u32", `Int 42) ] ] -> () | _ -> fail "Expected u32 as Int"

let test_decimal_string () =
  let cols = [ ("d", "Decimal(10,2)") ] in
  let rows = [ [ Proton.Column.String "123.45" ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("d", `String s) ] ] -> check string "decimal-string" "123.45" s
  | _ -> fail "Expected decimal as String"

let test_array_uint64 () =
  let cols = [ ("arr", "Array(UInt64)") ] in
  let rows =
    [
      [ Proton.Column.Array [| Proton.Column.UInt64 1L; Proton.Column.UInt64 9007199254740993L |] ];
    ]
  in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("arr", `List [ `Intlit "1"; `Intlit "9007199254740993" ]) ] ] -> ()
  | _ -> fail "Expected array of UInt64 as list of Intlit strings"

let test_map_string_u64 () =
  let cols = [ ("m", "Map(String, UInt64)") ] in
  let rows = [ [ Proton.Column.Map [ (Proton.Column.String "a", Proton.Column.UInt64 2L) ] ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("m", `Assoc [ ("a", `Intlit "2") ]) ] ] -> ()
  | _ -> fail "Expected map value as Intlit"

let test_tuple_u64_str () =
  let cols = [ ("t", "Tuple(UInt64, String)") ] in
  let rows = [ [ Proton.Column.Tuple [ Proton.Column.UInt64 3L; Proton.Column.String "x" ] ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("t", `List [ `Intlit "3"; `String "x" ]) ] ] -> ()
  | _ -> fail "Expected tuple converted element-wise"

let test_nullable_datetime_null () =
  let cols = [ ("ndt", "Nullable(DateTime)") ] in
  let rows = [ [ Proton.Column.Null ] ] in
  let j = to_json rows cols in
  match j with
  | `List [ `Assoc [ ("ndt", `Null) ] ] -> ()
  | _ -> fail "Expected Nullable(DateTime) as null"

let () =
  run "JSON Conversion Tests"
    [
      ( "numbers",
        [
          ("u64 string", `Quick, test_uint64_string);
          ("i64 string", `Quick, test_int64_string);
          ("u32 number", `Quick, test_uint32_number);
          ("decimal string", `Quick, test_decimal_string);
        ] );
      ( "complex",
        [
          ("array u64", `Quick, test_array_uint64);
          ("map string->u64", `Quick, test_map_string_u64);
          ("tuple u64,str", `Quick, test_tuple_u64_str);
          ("nullable dt null", `Quick, test_nullable_datetime_null);
        ] );
    ]
