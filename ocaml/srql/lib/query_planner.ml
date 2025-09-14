open Query_ast
open Ast

let and_opt a b = match (a,b) with | (None, x) -> x | (x, None) -> x | (Some l, Some r) -> Some (And (l, r))

let parse_stats (s:string) : (string list * string list) =
  (* returns (agg_selects, by_fields) and supports aliases via "as" *)
  let s = String.trim s in
  let lower = String.lowercase_ascii s in
  let by_idx =
    let rec find i =
      if i + 2 > String.length lower then None
      else if String.sub lower i 2 = "by" then Some i else find (i+1)
    in find 0
  in
  let agg_part, by_part =
    match by_idx with
    | Some i -> (String.sub s 0 i |> String.trim, String.sub s (i+2) (String.length s - i - 2) |> String.trim)
    | None -> (s, "")
  in
  let aggs = agg_part
             |> String.split_on_char ','
             |> List.map String.trim
             |> List.filter ((<>) "")
             |> List.map (fun a ->
                  let la = String.lowercase_ascii a in
                  match String.index_opt la 'a' with
                  | None -> a
                  | Some i ->
                      if i + 2 <= String.length la && String.sub la i 2 = "as" then
                        let lhs = String.sub a 0 i |> String.trim in
                        let rhs = String.sub a (i+2) (String.length a - i - 2) |> String.trim in
                        if rhs = "" then lhs else lhs ^ " AS " ^ rhs
                      else a)
  in
  let bys = if by_part = "" then [] else by_part |> String.split_on_char ',' |> List.map String.trim |> List.filter ((<>) "") in
  (aggs, bys)

let parse_having (s:string) : Ast.condition option =
  (* supports simple patterns like count()>10, avg(field)>=1.5, sum(bytes)<1000 *)
  let ops = [ (">=", Gte); ("<=", Lte); ("!=", Neq); (">", Gt); ("<", Lt); ("=", Eq) ] in
  let rec find_op = function
    | [] -> None
    | (sym, op)::rest -> (match String.index_opt s sym.[0] with
        | None -> find_op rest
        | Some i -> if i+String.length sym <= String.length s && String.sub s i (String.length sym) = sym then Some (i, (sym, op)) else find_op rest)
  in
  match find_op ops with
  | None -> None
  | Some (i, (sym, op)) ->
      let lhs = String.sub s 0 i |> String.trim in
      let rhs = String.sub s (i + String.length sym) (String.length s - i - String.length sym) |> String.trim in
      let v = match float_of_string_opt rhs with Some f -> Float f | None -> (match int_of_string_opt rhs with Some n -> Int n | None -> String rhs) in
      Some (Condition (lhs, op, v))

let condition_of_filter = function
  | AttributeFilter (k, op, v) -> Some (Condition (k, op, v))
  | ObservableFilter (_k, _v) -> None (* not handled here yet *)
  | TimeFilter _ -> None
  | TextSearch _ -> None

let plan_to_srql (q:query_spec) : Ast.query option =
  (* Support: in:<single entity> + attribute filters + optional limit + sort -> SRQL SELECT *)
  let entity =
    match q.targets with
    | (Entity ents)::_ -> (match ents with e::_ -> Some e | [] -> None)
    | _ -> None
  in
  match entity with
  | None -> None
  | Some ent ->
      (* attribute key mapping (friendly -> internal); minimal for now *)
      let map_key k =
        let kl = String.lowercase_ascii k in
        match String.lowercase_ascii ent, kl with
        | "logs", "service" -> "service" (* translator maps to service_name *)
        | "devices", ("ip" | "hostname" | "mac" | "site" | "name") -> kl
        | "connections", ("src_ip" | "dst_ip" | "src_port" | "dst_port" | "protocol") -> kl
        | "flows", ("src_ip" | "dst_ip" | "src_port" | "dst_port" | "protocol" | "bytes" | "packets") -> kl
        | _ -> kl
      in
      (* build combined conditions *)
      let attr_conds =
        q.filters
        |> List.filter_map (function
              | AttributeFilter (k, op, v) -> Some (Condition (map_key k, op, v))
              | _ -> None)
      in
      let cond =
        attr_conds
        |> List.fold_left (fun acc c -> and_opt acc (Some c)) None
      in
      (* time filter handling: time:last_24h, last_7d, last_30m, last_1h etc. *)
      let cond =
        let add_time acc tf =
          match tf with
          | TimeFilter s ->
              let ls = String.lowercase_ascii (String.trim s) in
              let ts_field = Entity_mapping.get_timestamp_field ent in
              let starts_with pref = let lp = String.length pref in String.length ls >= lp && String.sub ls 0 lp = pref in
              if ls = "today" then (
                and_opt acc (Some (Condition ("date(" ^ ts_field ^ ")", Eq, String "TODAY")))
              ) else if ls = "yesterday" then (
                and_opt acc (Some (Condition ("date(" ^ ts_field ^ ")", Eq, String "YESTERDAY")))
              ) else if starts_with "last_" then (
                let rest = String.sub ls 5 (String.length ls - 5) in
                let rec split_num i = if i < String.length rest && Char.code rest.[i] >= 48 && Char.code rest.[i] <= 57 then split_num (i+1) else i in
                let idx = split_num 0 in
                let n_str = String.sub rest 0 idx and unit = String.sub rest idx (String.length rest - idx) |> String.trim in
                match int_of_string_opt n_str with
                | None -> acc
                | Some n ->
                    let unit_sql = match unit with | "m" | "min" | "mins" -> "MINUTE" | "h" | "hr" | "hour" | "hours" -> "HOUR" | "d" | "day" | "days" -> "DAY" | "w" | "wk" | "week" | "weeks" -> "WEEK" | _ -> "HOUR" in
                    let expr = Printf.sprintf "now() - INTERVAL %d %s" n unit_sql in
                    and_opt acc (Some (Condition (ts_field, Gte, Expr expr)))
              ) else if String.length ls >= 2 && ls.[0] = '[' && ls.[String.length ls - 1] = ']' then (
                let inside = String.sub ls 1 (String.length ls - 2) in
                let parts = inside |> String.split_on_char ',' |> List.map String.trim in
                let parse_dt s = Expr (Printf.sprintf "parseDateTimeBestEffort('%s')" s) in
                match parts with
                | [start_s; end_s] when start_s <> "" && end_s <> "" ->
                    let c1 = Condition (ts_field, Gte, parse_dt start_s) in
                    let c2 = Condition (ts_field, Lte, parse_dt end_s) in
                    and_opt acc (Some (And (c1, c2)))
                | [start_s; ""] -> and_opt acc (Some (Condition (ts_field, Gte, parse_dt start_s)))
                | [""; end_s] -> and_opt acc (Some (Condition (ts_field, Lte, parse_dt end_s)))
                | _ -> acc
              ) else acc
          | _ -> acc
        in
        List.fold_left add_time cond q.filters
      in
      let limit = if q.stream then None else q.limit in
      (* stats: parse "count() by field1,field2"; window adds _window bucket *)
      let select_fields, group_by, order_by =
        match q.stats with
        | None -> (Some ["*"], None, q.sort)
        | Some s ->
            let (aggs, bys) = parse_stats s in
            let (sel0, gb0) = (aggs, bys) in
            (* window bucketing *)
            let (sel, gb, ob) =
              match q.window with
              | None -> (sel0, gb0, q.sort)
              | Some w ->
                  let ts_field = Entity_mapping.get_timestamp_field ent in
                  (* parse window, e.g. 1m,5m,1h,1d *)
                  let n_str = String.sub w 0 (String.length w - 1) in
                  let unit = String.sub w (String.length w - 1) 1 in
                  let n = match int_of_string_opt n_str with Some n -> n | None -> 1 in
                  let unit_sql = match String.lowercase_ascii unit with | "m" -> "MINUTE" | "h" -> "HOUR" | "d" -> "DAY" | _ -> "MINUTE" in
                  let bucket_expr = Printf.sprintf "toStartOfInterval(%s, INTERVAL %d %s) AS _window" ts_field n unit_sql in
                  let sel' = sel0 @ [bucket_expr] in
                  let gb' = gb0 @ ["_window"] in
                  let ob' = match q.sort with Some srt -> Some srt | None -> Some [ ("_window", Asc) ] in
                  (sel', gb', ob')
            in
            (Some sel, (if gb = [] then None else Some gb), ob)
      in
      let having = Option.bind q.having parse_having in
      let q_type = if q.stream then `Stream else `Select in
      Some {
        q_type;
        entity = ent;
        conditions = cond;
        limit;
        select_fields;
        order_by;
        group_by;
        having;
        latest = false;
      }
