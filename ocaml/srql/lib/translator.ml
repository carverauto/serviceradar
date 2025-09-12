(* file: srql/lib/translator.ml *)
open Ast

let rec translate_condition = function
  | Condition (field, op, value) ->
      let val_str = match value with
        | String s -> "'" ^ s ^ "'"
        | Int i -> string_of_int i
        | Bool b -> string_of_bool b
      in
      (match op with
        | Eq -> Printf.sprintf "%s = %s" field val_str
        | Neq -> Printf.sprintf "%s != %s" field val_str
        | Gt -> Printf.sprintf "%s > %s" field val_str
        | Gte -> Printf.sprintf "%s >= %s" field val_str
        | Lt -> Printf.sprintf "%s < %s" field val_str
        | Lte -> Printf.sprintf "%s <= %s" field val_str
        | Contains -> Printf.sprintf "position(%s, %s) > 0" field val_str
        | In -> Printf.sprintf "%s IN %s" field val_str
        | Like -> Printf.sprintf "%s LIKE %s" field val_str
        | ArrayContains -> 
            (* For array fields like discovery_sources, use has() function *)
            Printf.sprintf "has(%s, %s)" field val_str)
  | And (left, right) ->
      Printf.sprintf "(%s AND %s)" (translate_condition left) (translate_condition right)
  | Or (left, right) ->
      Printf.sprintf "(%s OR %s)" (translate_condition left) (translate_condition right)

(* Smart array field detection - these fields should use has() instead of = *)
let is_array_field field =
  let array_fields = [
    "discovery_sources"; "discovery_source"; "tags"; "categories";
    "allowed_databases"; "ssl_certificates"; "networks"; "labels"
  ] in
  List.mem (String.lowercase_ascii field) array_fields

(* Convert Eq operator to ArrayContains for known array fields *)
let rec smart_condition_conversion = function
  | Condition (field, Eq, value) when is_array_field field ->
      Condition (field, ArrayContains, value)
  | Condition (field, op, value) -> Condition (field, op, value)
  | And (left, right) -> And (smart_condition_conversion left, smart_condition_conversion right)
  | Or (left, right) -> Or (smart_condition_conversion left, smart_condition_conversion right)

let translate_query (q : query) : string =
  (* Use entity mapping to get the actual table name *)
  let actual_table = if q.entity = "" then "" else Entity_mapping.get_table_name q.entity in
  
  (* Apply smart condition conversion for array fields *)
  let conditions = match q.conditions with
    | Some conds -> Some (smart_condition_conversion conds)
    | None -> None
  in
  
  match q.q_type with
  | `Select ->
      let fields = match q.select_fields with
        | Some fs -> String.concat ", " fs
        | None -> "*"
      in
      let select_clause = "SELECT " ^ fields in
      if actual_table = "" then
        select_clause  (* Handle SELECT without FROM clause *)
      else
        let from_clause = " FROM " ^ actual_table in
        let where_clause = match conditions with
          | Some conds -> " WHERE " ^ (translate_condition conds)
          | None -> ""
        in
        let limit_clause = match q.limit with
          | Some n -> " LIMIT " ^ (string_of_int n)
          | None -> ""
        in
        select_clause ^ from_clause ^ where_clause ^ limit_clause
  | _ ->
      let select_clause = match q.q_type with
        | `Show | `Find -> "SELECT *"
        | `Count -> "SELECT count(*)"
        | `Select -> "SELECT *" (* fallback, though this case shouldn't happen *)
      in
      let from_clause = " FROM " ^ actual_table in
      let where_clause = match conditions with
        | Some conds -> " WHERE " ^ (translate_condition conds)
        | None -> ""
      in
      let limit_clause = match q.limit with
        | Some n -> " LIMIT " ^ (string_of_int n)
        | None -> ""
      in
      String.trim (select_clause ^ from_clause ^ where_clause ^ limit_clause)

(* The main function exposed to the web server *)
let process_srql_string (query_str : string) : (string, string) result =
  try
    let lexbuf = Lexing.from_string query_str in
    let ast = Parser.query Lexer.token lexbuf in
    let sql = translate_query ast in
    Ok sql
  with
  | Lexer.Error msg -> Error (Printf.sprintf "Lexing error: %s" msg)
  | Parser.Error -> Error (Printf.sprintf "Syntax error near character %d" (Lexing.lexeme_start (Lexing.from_string query_str)))
  | ex -> Error (Printf.sprintf "An unexpected error occurred: %s" (Printexc.to_string ex))
