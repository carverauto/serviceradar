(* file: srql/lib/translator.ml *)
open Sql_ir
open Field_mapping
open Sql_sanitize

let lc = String.lowercase_ascii
let trim = String.trim

let sanitize_projection ~entity field =
  let field_trimmed = trim field in
  if field_trimmed = "*" then "*"
  else if String.contains field_trimmed '(' || String.contains field_trimmed ' ' then (
    ensure_safe_expression ~context:"select expression" field_trimmed;
    field_trimmed)
  else map_field_name ~entity field_trimmed

let rec translate_condition ~entity = function
  | Condition (field, op, value) -> (
      let val_str =
        match value with
        | String s ->
            let escaped = escape_string_literal s in
            "'" ^ escaped ^ "'"
        | Int i -> string_of_int i
        | Bool b -> string_of_bool b
        | Expr e ->
            ensure_safe_expression ~context:"expression value" e;
            e
        | Float f ->
            let s = string_of_float f in
            if String.contains s '.' then s else s ^ ".0"
      in
      let field = map_field_name ~entity field in
      match op with
      | Eq -> (
          match value with
          | String s
            when let u = lc s in
                 u = "today" || u = "yesterday" ->
              let date_fun = if lc s = "today" then "today()" else "yesterday()" in
              if String.length field >= 8 && String.sub (lc field) 0 8 = "to_date(" then
                Printf.sprintf "%s = %s" field date_fun
              else Printf.sprintf "%s = %s" field val_str
          | _ -> Printf.sprintf "%s = %s" field val_str)
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
      Printf.sprintf "(%s AND %s)"
        (translate_condition ~entity left)
        (translate_condition ~entity right)
  | Or (left, right) ->
      Printf.sprintf "(%s OR %s)"
        (translate_condition ~entity left)
        (translate_condition ~entity right)
  | Not c -> Printf.sprintf "(NOT %s)" (translate_condition ~entity c)
  | Between (field, v1, v2) ->
      let f = map_field_name ~entity field in
      let s_of_v = function
        | String s -> "'" ^ escape_string_literal s ^ "'"
        | Int i -> string_of_int i
        | Bool b -> string_of_bool b
        | Expr e ->
            ensure_safe_expression ~context:"expression value" e;
            e
        | Float f ->
            let s = string_of_float f in
            if String.contains s '.' then s else s ^ ".0"
      in
      Printf.sprintf "%s BETWEEN %s AND %s" f (s_of_v v1) (s_of_v v2)
  | IsNull field ->
      let f = map_field_name ~entity field in
      Printf.sprintf "%s IS NULL" f
  | IsNotNull field ->
      let f = map_field_name ~entity field in
      Printf.sprintf "%s IS NOT NULL" f
  | InList (field, vs) ->
      let f = map_field_name ~entity field in
      let s_of_v = function
        | String s -> "'" ^ escape_string_literal s ^ "'"
        | Int i -> string_of_int i
        | Bool b -> string_of_bool b
        | Expr e ->
            ensure_safe_expression ~context:"expression value" e;
            e
        | Float f ->
            let s = string_of_float f in
            if String.contains s '.' then s else s ^ ".0"
      in
      let items = vs |> List.map s_of_v |> String.concat ", " in
      Printf.sprintf "%s IN (%s)" f items

(* Smart array field detection - these fields should use has() instead of = *)
let is_array_field field =
  let array_fields =
    [
      "discovery_sources";
      "discovery_source";
      "tags";
      "categories";
      "allowed_databases";
      "ssl_certificates";
      "networks";
      "labels";
      (* common arrays in device and OCSF schemas *)
      "ip";
      "mac";
      "device_ip";
      "device_mac";
      "observables_ip";
      "observables_mac";
      "observables_hostname";
    ]
  in
  List.mem (String.lowercase_ascii field) array_fields

(* Convert Eq operator to ArrayContains for known array fields *)
let rec smart_condition_conversion = function
  | Condition (field, Eq, value) when is_array_field field -> Condition (field, ArrayContains, value)
  | Condition (field, op, value) -> Condition (field, op, value)
  | And (left, right) -> And (smart_condition_conversion left, smart_condition_conversion right)
  | Or (left, right) -> Or (smart_condition_conversion left, smart_condition_conversion right)
  | Not c -> Not (smart_condition_conversion c)
  | Between (f, v1, v2) -> Between (f, v1, v2)
  | IsNull f -> IsNull f
  | IsNotNull f -> IsNotNull f
  | InList (f, vs) -> InList (f, vs)

let translate_query (q : query) : string =
  (* Use entity mapping to get the actual table name *)
  let actual_table = if q.entity = "" then "" else Entity_mapping.get_table_name q.entity in

  (* Apply smart condition conversion for array fields *)
  let conditions =
    match q.conditions with Some conds -> Some (smart_condition_conversion conds) | None -> None
  in

  match q.q_type with
  | `Stream ->
      (* Streaming mode: no table() wrapper, no implicit device deletion filter, no LIMIT *)
      let fields =
        match q.select_fields with
        | Some fs -> List.map (sanitize_projection ~entity:q.entity) fs
        | None -> [ "*" ]
      in
      let select_clause = "SELECT " ^ String.concat ", " fields in
      if actual_table = "" then select_clause
      else
        let from_clause = " FROM " ^ actual_table in
        let where_clause =
          let cond_sql =
            match conditions with
            | Some conds -> Some (translate_condition ~entity:q.entity conds)
            | None -> None
          in
          let default_filters =
            let e = lc q.entity in
            let filters = ref [] in
            if e = "devices" then
              filters := !filters @ [ "coalesce(metadata['_deleted'], '') != 'true'" ];
            if e = "sweep_results" then filters := !filters @ [ "has(discovery_sources, 'sweep')" ];
            if e = "snmp_results" || e = "snmp_metrics" then
              filters := !filters @ [ "metric_type = 'snmp'" ];
            !filters
          in
          match (cond_sql, default_filters) with
          | None, [] -> ""
          | Some c, [] -> " WHERE " ^ c
          | None, ds -> " WHERE " ^ String.concat " AND " ds
          | Some c, ds -> " WHERE (" ^ c ^ ") AND " ^ String.concat " AND " ds
        in
        let group_clause =
          match q.group_by with
          | Some lst when lst <> [] ->
              let mapped = List.map (map_field_name ~entity:q.entity) lst in
              " GROUP BY " ^ String.concat ", " mapped
          | _ -> ""
        in
        let having_clause =
          match q.having with
          | Some cond -> " HAVING " ^ translate_condition ~entity:q.entity cond
          | None -> ""
        in
        let order_clause =
          match q.order_by with
          | Some lst when lst <> [] ->
              let part (f, d) =
                map_field_name ~entity:q.entity f
                ^ match d with Sql_ir.Asc -> " ASC" | Sql_ir.Desc -> " DESC"
              in
              " ORDER BY " ^ String.concat ", " (List.map part lst)
          | _ -> ""
        in
        select_clause ^ from_clause ^ where_clause ^ group_clause ^ having_clause ^ order_clause
  | `Select ->
      let fields =
        match q.select_fields with
        | Some fs -> List.map (sanitize_projection ~entity:q.entity) fs
        | None -> [ "*" ]
      in
      let select_clause = "SELECT " ^ String.concat ", " fields in
      if actual_table = "" then select_clause (* Handle SELECT without FROM clause *)
      else
        let from_clause = " FROM table(" ^ actual_table ^ ")" in
        let where_clause =
          let cond_sql =
            match conditions with
            | Some conds -> Some (translate_condition ~entity:q.entity conds)
            | None -> None
          in
          let default_filters =
            let e = lc q.entity in
            let filters = ref [] in
            if e = "devices" then
              filters := !filters @ [ "coalesce(metadata['_deleted'], '') != 'true'" ];
            if e = "sweep_results" then filters := !filters @ [ "has(discovery_sources, 'sweep')" ];
            if e = "snmp_results" || e = "snmp_metrics" then
              filters := !filters @ [ "metric_type = 'snmp'" ];
            !filters
          in
          match (cond_sql, default_filters) with
          | None, [] -> ""
          | Some c, [] -> " WHERE " ^ c
          | None, ds -> " WHERE " ^ String.concat " AND " ds
          | Some c, ds -> " WHERE (" ^ c ^ ") AND " ^ String.concat " AND " ds
        in
        let group_clause =
          match q.group_by with
          | Some lst when lst <> [] ->
              let mapped = List.map (map_field_name ~entity:q.entity) lst in
              " GROUP BY " ^ String.concat ", " mapped
          | _ -> ""
        in
        let having_clause =
          match q.having with
          | Some cond -> " HAVING " ^ translate_condition ~entity:q.entity cond
          | None -> ""
        in
        let order_clause =
          match q.order_by with
          | Some lst when lst <> [] ->
              let part (f, d) =
                map_field_name ~entity:q.entity f
                ^ match d with Sql_ir.Asc -> " ASC" | Sql_ir.Desc -> " DESC"
              in
              " ORDER BY " ^ String.concat ", " (List.map part lst)
          | _ -> ""
        in
        let limit_clause =
          match q.limit with Some n -> " LIMIT " ^ string_of_int n | None -> ""
        in
        select_clause ^ from_clause ^ where_clause ^ group_clause ^ having_clause ^ order_clause
        ^ limit_clause

(* Legacy SRQL parsing has been removed from the library build. *)
