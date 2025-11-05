open Sql_ir

let lc = String.lowercase_ascii
let trim = String.trim

let split_as s =
  match String.index_opt (lc s) 'a' with
  | None -> (s, None)
  | Some i ->
      if i + 2 <= String.length s && String.sub (lc s) i 2 = "as" then
        (String.sub s 0 i |> trim, Some (String.sub s (i + 2) (String.length s - i - 2) |> trim))
      else (s, None)

let is_agg_expr s =
  let ls = lc s in
  String.contains ls '(' && String.contains ls ')'

let collect_aliases (fields : string list) : string list =
  fields
  |> List.filter_map (fun f ->
         let _lhs, a = split_as f in
         a)

let validate_select_vs_group_by ~(select_fields : string list) ~(group_by : string list) :
    (unit, string) result =
  let gb_set = List.sort_uniq String.compare (List.map lc group_by) in
  let offenders =
    select_fields
    |> List.filter_map (fun f ->
           let f = trim f in
           let lhs, _alias = split_as f in
           let lhs = trim lhs in
           if is_agg_expr lhs then None
           else
             let fld = lc lhs in
             if List.mem fld gb_set then None else Some lhs)
  in
  match offenders with
  | [] -> Ok ()
  | xs ->
      let suggestion =
        if group_by = [] then
          "Consider adding a GROUP BY clause including these fields or wrapping them in aggregates."
        else Printf.sprintf "Add to GROUP BY: %s or aggregate them." (String.concat ", " xs)
      in
      Error
        (Printf.sprintf "Non-aggregated fields in SELECT not in GROUP BY: %s. %s"
           (String.concat ", " xs) suggestion)

let validate_having ~(having : condition) ~(select_fields : string list) ~(group_by : string list) :
    (unit, string) result =
  let aliases = collect_aliases select_fields |> List.map lc in
  let gb = List.map lc group_by in
  let rec lhs_of = function
    | Condition (lhs, _, _) -> lhs
    | And (l, _) -> lhs_of l
    | Or (l, _) -> lhs_of l
    | Not c -> lhs_of c
    | Between (lhs, _, _) -> lhs
    | IsNull lhs -> lhs
    | IsNotNull lhs -> lhs
    | InList (lhs, _) -> lhs
    | HasKey (map_name, key_name) -> Printf.sprintf "%s.%s" map_name key_name
  in
  let lhs = lhs_of having |> trim in
  let lclhs = lc lhs in
  if is_agg_expr lhs then Ok ()
  else if List.mem lclhs aliases then Ok ()
  else if List.mem lclhs (List.map lc select_fields) then Ok ()
  else if List.mem lclhs gb then Ok ()
  else
    let available =
      let sel_names = select_fields |> List.map (fun s -> fst (split_as s) |> trim) in
      "Available: aggregates/Aliases: " ^ String.concat ", " aliases
      ^ (if gb = [] then "" else "; Grouped fields: " ^ String.concat ", " group_by)
      ^ if sel_names = [] then "" else "; Selected: " ^ String.concat ", " sel_names
    in
    Error (Printf.sprintf "Invalid HAVING reference '%s'. %s" lhs available)

let validate (q : query) : (unit, string) result =
  (* Validate SELECT vs GROUP BY when both present *)
  let res =
    match (q.select_fields, q.group_by) with
    | Some fs, Some gb when fs <> [ "*" ] ->
        validate_select_vs_group_by ~select_fields:fs ~group_by:gb
    | _ -> Ok ()
  in
  match (res, q.having, q.select_fields, q.group_by) with
  | Error e, _, _, _ -> Error e
  | Ok (), None, _, _ -> Ok ()
  | Ok (), Some h, Some fs, Some gb -> validate_having ~having:h ~select_fields:fs ~group_by:gb
  | Ok (), Some h, Some fs, None ->
      (* Even without GROUP BY, HAVING must reference aggregates or aliases from SELECT *)
      validate_having ~having:h ~select_fields:fs ~group_by:[]
  | _ -> Ok ()
