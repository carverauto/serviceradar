(* file: srql/lib/translator.ml *)
open Ast

let rec translate_condition = function
  | Condition (field, op, value) ->
      let op_str = match op with
        | Eq -> "="
        | Neq -> "!="
        | Gt -> ">"
        | Gte -> ">="
        | Lt -> "<"
        | Lte -> "<="
        | Contains -> "CONTAINS" (* This will be adapted later *)
      in
      let val_str = match value with
        | String s -> "'" ^ s ^ "'"
        | Int i -> string_of_int i
        | Bool b -> string_of_bool b
      in
      if op = Contains then
        Printf.sprintf "position(%s, %s) > 0" field val_str
      else
        Printf.sprintf "%s %s %s" field op_str val_str
  | And (left, right) ->
      Printf.sprintf "(%s AND %s)" (translate_condition left) (translate_condition right)
  | Or (left, right) ->
      Printf.sprintf "(%s OR %s)" (translate_condition left) (translate_condition right)

let translate_query (q : query) : string =
  let select_clause = match q.q_type with
    | `Show | `Find -> "SELECT *"
    | `Count -> "SELECT count()"
  in
  let from_clause = "FROM " ^ q.entity in
  let where_clause = match q.conditions with
    | Some conds -> "WHERE " ^ (translate_condition conds)
    | None -> ""
  in
  let limit_clause = match q.limit with
    | Some n -> "LIMIT " ^ (string_of_int n)
    | None -> ""
  in
  String.trim (Printf.sprintf "%s %s %s %s" select_clause from_clause where_clause limit_clause)

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
