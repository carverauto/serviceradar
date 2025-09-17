open Sql_ir

module String_utils = struct
  let trim = String.trim

  let starts_with_icase ~prefix s =
    let len_p = String.length prefix and len_s = String.length s in
    if len_p > len_s then false
    else String.lowercase_ascii (String.sub s 0 len_p) = String.lowercase_ascii prefix

  let index_of_sub_icase ?(start = 0) s sub =
    let ls = String.lowercase_ascii s in
    let lsub = String.lowercase_ascii sub in
    let len_s = String.length s and len_sub = String.length sub in
    let rec search i =
      if i + len_sub > len_s then None
      else if i < start then search (i + 1)
      else if String.sub ls i len_sub = lsub then Some i
      else search (i + 1)
    in
    search start

  let split_on_comma text =
    let buf = Buffer.create (String.length text) in
    let parts = ref [] in
    let depth = ref 0 in
    let push () =
      let v = Buffer.contents buf |> String.trim in
      if v <> "" then parts := !parts @ [ v ];
      Buffer.clear buf
    in
    String.iter
      (fun c ->
        match c with
        | '(' ->
            incr depth;
            Buffer.add_char buf c
        | ')' ->
            decr depth;
            Buffer.add_char buf c
        | ',' when !depth = 0 -> push ()
        | _ -> Buffer.add_char buf c)
      text;
    push ();
    !parts
end

open String_utils

type translation = { sql : string; order : (string * order_dir) list; limit : int option }

let entity_table entity = Entity_mapping.get_table_name (String.lowercase_ascii entity)
let timestamp_for_entity entity = Entity_mapping.get_timestamp_field (String.lowercase_ascii entity)

let normalize_default_time_value (value : string option) : string option =
  match value with
  | Some raw -> (
      let trimmed = trim raw in
      if trimmed = "" then None
      else
        match String.lowercase_ascii trimmed with
        | "auto" | "none" | "unbounded" -> None
        | _ -> Some trimmed)
  | None -> None

let has_time_filter entity where_clause =
  if where_clause = "" then false
  else
    let ts_field = timestamp_for_entity entity in
    let candidates =
      [
        ts_field;
        "timestamp";
        "event_timestamp";
        "event_time";
        "last_seen";
        "observed_time";
        "collection_time";
        "ingest_time";
        "time(";
        "date(";
      ]
    in
    List.exists
      (fun needle ->
        match index_of_sub_icase where_clause needle with Some _ -> true | None -> false)
      candidates

let build_default_time_clause entity default_time =
  let ts_field = timestamp_for_entity entity in
  let trimmed = trim default_time in
  if trimmed = "" then None
  else
    let lower = String.lowercase_ascii trimmed in
    if lower = "today" then Some (Printf.sprintf "toDate(%s) = today()" ts_field)
    else if lower = "yesterday" then Some (Printf.sprintf "toDate(%s) = yesterday()" ts_field)
    else if String.length lower > 5 && String.sub lower 0 5 = "last_" then
      let rest = String.sub trimmed 5 (String.length trimmed - 5) in
      let rec find_digits idx =
        if idx < String.length rest && Char.code rest.[idx] >= 48 && Char.code rest.[idx] <= 57 then
          find_digits (idx + 1)
        else idx
      in
      let digits_end = find_digits 0 in
      if digits_end = 0 then None
      else
        let number_str = String.sub rest 0 digits_end |> trim in
        match int_of_string_opt number_str with
        | None -> None
        | Some n when n <= 0 -> None
        | Some n ->
            let unit_raw =
              if digits_end >= String.length rest then ""
              else
                String.sub rest digits_end (String.length rest - digits_end)
                |> trim |> String.lowercase_ascii
            in
            let unit_sql =
              match unit_raw with
              | "" | "h" | "hr" | "hrs" | "hour" | "hours" -> "HOUR"
              | "m" | "min" | "mins" | "minute" | "minutes" -> "MINUTE"
              | "s" | "sec" | "secs" | "second" | "seconds" -> "SECOND"
              | "d" | "day" | "days" -> "DAY"
              | "w" | "wk" | "wks" | "week" | "weeks" -> "WEEK"
              | "mo" | "mon" | "mons" | "month" | "months" -> "MONTH"
              | "y" | "yr" | "yrs" | "year" | "years" -> "YEAR"
              | _ -> "HOUR"
            in
            Some (Printf.sprintf "%s >= now() - INTERVAL %d %s" ts_field n unit_sql)
    else if
      String.length trimmed >= 2 && trimmed.[0] = '[' && trimmed.[String.length trimmed - 1] = ']'
    then
      let inside = String.sub trimmed 1 (String.length trimmed - 2) in
      let parts = inside |> String.split_on_char ',' |> List.map trim in
      match parts with
      | [ start_s; end_s ] -> (
          let start_clause =
            if start_s = "" then None
            else
              Some
                (Printf.sprintf "%s >= parseDateTimeBestEffort('%s')" ts_field
                   (Sql_sanitize.escape_string_literal start_s))
          in
          let end_clause =
            if end_s = "" then None
            else
              Some
                (Printf.sprintf "%s <= parseDateTimeBestEffort('%s')" ts_field
                   (Sql_sanitize.escape_string_literal end_s))
          in
          match (start_clause, end_clause) with
          | Some s, Some e -> Some ("(" ^ s ^ " AND " ^ e ^ ")")
          | Some s, None -> Some s
          | None, Some e -> Some e
          | None, None -> None)
      | _ -> None
    else None

let apply_default_time_clause ~entity ~where_clause ~default_time =
  let default_time =
    match default_time with
    | Some _ -> default_time
    | None -> (
        match String.lowercase_ascii entity with
        | "logs" | "events" | "otel_metrics" | "otel_traces" -> Some "last_24h"
        | _ -> None)
  in
  match default_time with
  | None -> where_clause
  | Some dt -> (
      if has_time_filter entity where_clause then where_clause
      else
        match build_default_time_clause entity dt with
        | None -> where_clause
        | Some clause when where_clause = "" -> clause
        | Some clause -> where_clause ^ " AND " ^ clause)

let parse_order_by clause =
  clause |> split_on_comma
  |> List.filter_map (fun part ->
         let trimmed = trim part in
         if trimmed = "" then None
         else
           let pieces = trimmed |> String.split_on_char ' ' |> List.filter (fun s -> s <> "") in
           match pieces with
           | [] -> None
           | field :: rest ->
               let dir =
                 match rest with
                 | first :: _ when String.lowercase_ascii first = "desc" -> Desc
                 | _ -> Asc
               in
               Some (field, dir))

let normalize_limit clause =
  let trimmed = trim clause in
  if trimmed = "" then None
  else
    let first_token =
      match String.split_on_char ' ' trimmed with hd :: _ -> trim hd | [] -> trimmed
    in
    match int_of_string_opt first_token with Some v -> Some v | None -> None

let translate_distinct query req_limit default_time =
  let prefix = "show distinct(" in
  if not (starts_with_icase ~prefix query) then None
  else
    match index_of_sub_icase query ")" with
    | None -> None
    | Some idx_end_fn -> (
        let field =
          String.sub query (String.length prefix) (idx_end_fn - String.length prefix) |> trim
        in
        let after =
          if idx_end_fn + 1 >= String.length query then ""
          else String.sub query (idx_end_fn + 1) (String.length query - idx_end_fn - 1)
        in
        match index_of_sub_icase after " from " with
        | None -> None
        | Some idx_from ->
            let rest =
              String.sub after (idx_from + 6) (String.length after - idx_from - 6) |> trim
            in
            if rest = "" then None
            else
              let idx_where = index_of_sub_icase rest " where " in
              let idx_order = index_of_sub_icase rest " order by " in
              let idx_limit = index_of_sub_icase rest " limit " in
              let entity_end =
                match
                  List.filter_map (fun x -> x) [ idx_where; idx_order; idx_limit ]
                  |> List.sort compare
                with
                | next :: _ -> next
                | [] -> String.length rest
              in
              let entity = String.sub rest 0 entity_end |> trim in
              if entity = "" then None
              else
                let where_clause =
                  match idx_where with
                  | Some i ->
                      let start = i + 7 in
                      let stop =
                        List.fold_left
                          (fun acc v -> match v with Some j when j > i && j < acc -> j | _ -> acc)
                          (String.length rest) [ idx_order; idx_limit ]
                      in
                      String.sub rest start (stop - start) |> trim
                  | None -> ""
                in
                let where_clause = apply_default_time_clause ~entity ~where_clause ~default_time in
                let order_clause =
                  match idx_order with
                  | Some i ->
                      let start = i + 10 in
                      let stop =
                        match idx_limit with Some j when j > i -> j | _ -> String.length rest
                      in
                      String.sub rest start (stop - start) |> trim
                  | None -> ""
                in
                let limit_clause =
                  match idx_limit with
                  | Some i ->
                      let start = i + 7 in
                      String.sub rest start (String.length rest - start) |> trim
                  | None -> ""
                in
                let table = entity_table entity in
                let base = Printf.sprintf "SELECT DISTINCT %s FROM %s" field table in
                let base = if where_clause = "" then base else base ^ " WHERE " ^ where_clause in
                let base, order_fields =
                  if order_clause = "" then (base, [])
                  else (base ^ " ORDER BY " ^ order_clause, parse_order_by order_clause)
                in
                let effective_limit =
                  match normalize_limit limit_clause with Some v -> Some v | None -> req_limit
                in
                let sql =
                  if limit_clause <> "" then base ^ " LIMIT " ^ limit_clause
                  else
                    match effective_limit with
                    | Some v -> base ^ Printf.sprintf " LIMIT %d" v
                    | None -> base
                in
                Some { sql; order = order_fields; limit = effective_limit })

let translate_simple query req_limit default_time =
  let normalized = trim query in
  if normalized = "" then None
  else
    let handle command keyword_len =
      let rest =
        String.sub normalized keyword_len (String.length normalized - keyword_len) |> trim
      in
      if rest = "" then None
      else
        let idx_where = index_of_sub_icase rest " where " in
        let idx_order = index_of_sub_icase rest " order by " in
        let idx_limit = index_of_sub_icase rest " limit " in
        let idx_latest = index_of_sub_icase rest " latest" in
        let earliest =
          List.filter_map (fun x -> x) [ idx_where; idx_order; idx_limit; idx_latest ]
          |> List.sort compare
          |> function
          | [] -> None
          | x :: _ -> Some x
        in
        let entity_end, latest_flag =
          match (idx_latest, earliest) with
          | Some idx, Some min_idx when idx < min_idx -> (idx, true)
          | Some idx, None -> (idx, true)
          | _ -> (
              match earliest with Some idx -> (idx, false) | None -> (String.length rest, false))
        in
        let entity = if entity_end <= 0 then rest else String.sub rest 0 entity_end |> trim in
        if entity = "" then None
        else
          let remainder_start =
            if latest_flag then min (entity_end + String.length " latest") (String.length rest)
            else entity_end
          in
          let remainder =
            if remainder_start >= String.length rest then ""
            else String.sub rest remainder_start (String.length rest - remainder_start)
          in
          let remainder = trim remainder in
          let idx_where = index_of_sub_icase remainder " where " in
          let idx_order = index_of_sub_icase remainder " order by " in
          let idx_limit = index_of_sub_icase remainder " limit " in
          let where_clause =
            match idx_where with
            | Some i ->
                let start = i + 7 in
                let stop =
                  List.fold_left
                    (fun acc v -> match v with Some j when j > i && j < acc -> j | _ -> acc)
                    (String.length remainder) [ idx_order; idx_limit ]
                in
                String.sub remainder start (stop - start) |> trim
            | None -> ""
          in
          let where_clause = apply_default_time_clause ~entity ~where_clause ~default_time in
          let order_clause =
            match idx_order with
            | Some i ->
                let start = i + 10 in
                let stop =
                  match idx_limit with Some j when j > i -> j | _ -> String.length remainder
                in
                String.sub remainder start (stop - start) |> trim
            | None -> ""
          in
          let limit_clause =
            match idx_limit with
            | Some i ->
                let start = i + 7 in
                String.sub remainder start (String.length remainder - start) |> trim
            | None -> ""
          in
          let table = entity_table entity in
          let select_expr = match command with `Count -> "count()" | `Show -> "*" in
          let base = Printf.sprintf "SELECT %s FROM %s" select_expr table in
          let base = if where_clause = "" then base else base ^ " WHERE " ^ where_clause in
          let applied_order, order_fields =
            if order_clause <> "" then (Some order_clause, parse_order_by order_clause)
            else if latest_flag then
              let clause = timestamp_for_entity entity ^ " DESC" in
              (Some clause, parse_order_by clause)
            else (None, [])
          in
          let base =
            match applied_order with Some clause -> base ^ " ORDER BY " ^ clause | None -> base
          in
          let effective_limit =
            match normalize_limit limit_clause with Some v -> Some v | None -> req_limit
          in
          let sql =
            if limit_clause <> "" then base ^ " LIMIT " ^ limit_clause
            else if command <> `Count then
              match effective_limit with
              | Some v -> base ^ Printf.sprintf " LIMIT %d" v
              | None -> base
            else base
          in
          Some { sql; order = order_fields; limit = effective_limit }
    in
    if starts_with_icase ~prefix:"show " normalized then handle `Show 5
    else if starts_with_icase ~prefix:"find " normalized then handle `Show 5
    else if starts_with_icase ~prefix:"count " normalized then handle `Count 6
    else None

let translate ?req_limit ?default_time query =
  let req_limit = match req_limit with Some v when v > 0 -> Some v | _ -> None in
  let default_time =
    match normalize_default_time_value default_time with
    | Some v -> Some v
    | None -> normalize_default_time_value (Sys.getenv_opt "SRQL_DEFAULT_TIME")
  in
  match translate_distinct query req_limit default_time with
  | Some t -> Some t
  | None -> translate_simple query req_limit default_time
