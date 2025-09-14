open Query_ast
open Sql_ir

(* Optional default time window, configurable by server/header/env. *)
let default_time_ref : string option ref = ref None

let set_default_time (v:string option) =
  default_time_ref := v

let and_opt a b = match (a,b) with | (None, x) -> x | (x, None) -> x | (Some l, Some r) -> Some (And (l, r))

let normalize_agg (a:string) : string =
  let s = String.trim a in
  let lower = String.lowercase_ascii s in
  (* keep alias if present: split by " as " last occurrence *)
  let alias_split l =
    match String.index_opt l 'a' with
    | None -> (l, None)
    | Some i -> if i + 2 <= String.length l && String.sub l i 2 = "as"
                then (String.sub l 0 i |> String.trim, Some (String.sub s (i+2) (String.length s - i - 2) |> String.trim))
                else (l, None)
  in
  let body_l, alias_opt = alias_split lower in
  let body = String.sub s 0 (String.length body_l) in
  let with_alias expr = match alias_opt with Some al when al <> "" -> expr ^ " AS " ^ al | _ -> expr in
  let starts_with pref = let lp = String.length pref in String.length body_l >= lp && String.sub body_l 0 lp = pref in
  (* topk is handled elsewhere *)
  if starts_with "count_distinct(" || starts_with "distinct_count(" then (
    let inner = String.sub body (String.index body '(' + 1) (String.rindex body ')' - (String.index body '(') - 1) |> String.trim in
    with_alias ("uniq(" ^ inner ^ ")")
  ) else if starts_with "p" && String.length body_l > 2 && body_l.[1] >= '0' && body_l.[1] <= '9' then (
    (* p95(field) -> quantile(0.95)(field) *)
    try
      let i_par = String.index body '(' in
      let fn = String.sub body_l 0 i_par in
      let perc = String.sub fn 1 (String.length fn - 1) |> int_of_string in
      let inner = String.sub body (i_par+1) (String.rindex body ')' - i_par - 1) |> String.trim in
      let q = float_of_int perc /. 100.0 in
      with_alias (Printf.sprintf "quantile(%0.2f)(%s)" q inner)
    with _ -> s
  ) else s

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
  let split_top_level_commas str =
    let parts = ref [] in
    let buf = Buffer.create (String.length str) in
    let depth = ref 0 in
    let push () = let v = Buffer.contents buf |> String.trim in if v <> "" then parts := !parts @ [v]; Buffer.clear buf in
    String.iter (fun c -> match c with
      | '(' -> incr depth; Buffer.add_char buf c
      | ')' -> decr depth; Buffer.add_char buf c
      | ',' when !depth = 0 -> push ()
      | _ -> Buffer.add_char buf c
    ) str;
    push (); !parts
  in
  let aggs = split_top_level_commas agg_part
             |> List.map normalize_agg
  in
  let bys = if by_part = "" then [] else by_part |> String.split_on_char ',' |> List.map String.trim |> List.filter ((<>) "") in
  (aggs, bys)

let parse_having (s:string) : Sql_ir.condition option =
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
  | AttributeFilter (k, op, v) ->
      (match v, op with
       | String s, Eq when String.contains s '%' -> Some (Condition (k, Like, v))
       | String s, Neq when String.contains s '%' -> Some (Not (Condition (k, Like, v)))
       | _ -> Some (Condition (k, op, v)))
  | AttributeListFilter (k, vs) -> Some (InList (k, vs))
  | AttributeListFilterNot (k, vs) -> Some (Not (InList (k, vs)))
  | ObservableFilter (_k, _v) -> None (* not handled here yet *)
  | TimeFilter _ -> None
  | TextSearch _ -> None

let plan_to_srql (q:query_spec) : Sql_ir.query option =
  (* Support: in:<single entity> + attribute filters + optional limit + sort -> SRQL SELECT *)
  let entity =
    match q.targets with
    | (Entity ents)::_ -> (match ents with e::_ -> Some e | [] -> None)
    | _ -> None
  in
  match entity with
  | None -> None
  | Some ent ->
      (* entity aliases *)
      let ent = let le = String.lowercase_ascii ent in if le = "activity" then "events" else ent in
      (* attribute key mapping (friendly -> internal); minimal for now *)
      let map_key k =
        let kl0 = String.lowercase_ascii k in
        (* boundary alias -> partition, including nested suffixes like ".boundary" *)
        let kl =
          if kl0 = "boundary" then "partition"
          else if String.length kl0 > 9 && String.sub kl0 (String.length kl0 - 9) 9 = ".boundary" then
            (String.sub kl0 0 (String.length kl0 - 9)) ^ ".partition"
          else kl0
        in
        match String.lowercase_ascii ent, kl with
        | "logs", ("service" | "service.name") -> "service"
        | "logs", ("endpoint.hostname") -> "endpoint_hostname"
        | "devices", ("ip" | "hostname" | "mac" | "site" | "name" | "device_name" | "ip_address" | "mac_address" | "uid") -> kl
        | "devices", ("device.ip") -> "ip"
        | "devices", ("device.mac") -> "mac"
        | "devices", ("device.os.name") -> "device_os_name"
        | "devices", ("device.os.version") -> "device_os_version"
        | "devices", ("partition" | "device.partition" | "device_partition") -> "partition"
        | "connections", ("src_ip" | "dst_ip" | "src_port" | "dst_port" | "protocol") -> kl
        | "flows", ("src_ip" | "dst_ip" | "src_port" | "dst_port" | "protocol" | "bytes" | "packets") -> kl
        | _ -> kl
      in
      (* maybe inject default time window if none provided *)
      let q =
        let has_time = List.exists (function | TimeFilter _ -> true | _ -> false) q.filters in
        if has_time then q else (
          let from_env = Sys.getenv_opt "SRQL_DEFAULT_TIME" in
          let chosen = match !default_time_ref with Some s -> Some s | None -> from_env in
          match chosen with
          | Some s when String.trim s <> "" -> { q with filters = q.filters @ [ TimeFilter s ] }
          | _ -> q
        )
      in
      (* build combined conditions using condition_of_filter and key mapping *)
      let attr_conds =
        q.filters
        |> List.filter_map (fun f ->
            match f with
            | AttributeFilter (k, op, v) -> condition_of_filter (AttributeFilter (map_key k, op, v))
            | AttributeListFilter (k, vs) -> condition_of_filter (AttributeListFilter (map_key k, vs))
            | AttributeListFilterNot (k, vs) -> condition_of_filter (AttributeListFilterNot (map_key k, vs))
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
      (* stats: parse aggregations; support topk(field, N); window adds _window bucket *)
      let select_fields, group_by, order_by, limit =
        match q.stats with
        | None -> (Some ["*"], None, q.sort, limit)
        | Some s ->
            let (aggs_all, bys_raw) = parse_stats s in
            let bys = List.map map_key bys_raw in
            (* topk_by(expr, N) detection and rewrite *)
            let topk_by_info =
              let l = String.lowercase_ascii s in
              let key = "topk_by" in
              let rec find i = if i + String.length key > String.length l then None else if String.sub l i (String.length key) = key then Some i else find (i+1) in
              match find 0 with
              | None -> None
              | Some i ->
                  (try
                     let i_par = String.index_from s i '(' in
                     let j_par = String.rindex s ')' in
                     let inside = String.sub s (i_par+1) (j_par - i_par - 1) |> String.trim in
                     (* split last comma as N, rest is expression (may contain commas inside nested functions) *)
                     let last_comma = String.rindex_opt inside ',' in
                     match last_comma with
                     | None -> None
                     | Some j ->
                         let expr = String.sub inside 0 j |> String.trim in
                         let nstr = String.sub inside (j+1) (String.length inside - j - 1) |> String.trim in
                         (match int_of_string_opt nstr with Some n -> Some (expr, n) | None -> None)
                   with _ -> None)
            in
            (* topk(field, N) detection and rewrite *)
            let topk_info =
              let l = String.lowercase_ascii s in
              let rec find i = if i + 4 > String.length l then None else if String.sub l i 4 = "topk" then Some i else find (i+1) in
              match find 0 with
              | None -> None
              | Some i ->
                  (try
                     let i_par = String.index_from s i '(' in
                     let j_par = String.index_from s i_par ')' in
                     let inside = String.sub s (i_par+1) (j_par - i_par - 1) |> String.trim in
                     let parts = inside |> String.split_on_char ',' |> List.map String.trim in
                     match parts with
                     | [field; nstr] -> (match int_of_string_opt nstr with Some n -> Some (field, n) | None -> Some (field, 10))
                     | [field] -> Some (field, 10)
                     | _ -> None
                   with _ -> None)
            in
            let sel0, gb0, ob0, lim0 =
              match topk_by_info with
              | Some (expr, n) ->
                  (* topk_by requires group-by keys to rank groups by an aggregate expression *)
                  let expr_norm = normalize_agg expr in
                  let metric_alias = "metric" in
                  let expr_with_alias = expr_norm ^ " AS " ^ metric_alias in
                  let base_sel = bys @ [expr_with_alias] in
                  let full_sel = base_sel @ (aggs_all |> List.filter (fun a ->
                    let la = String.lowercase_ascii (String.trim a) in not (String.length la >= 8 && String.sub la 0 8 = "topk_by(")
                  )) in
                  let ob = Some [ (metric_alias, Desc) ] in
                  (full_sel, bys, ob, Some n)
              | None -> (
                  match topk_info with
                  | Some (field, n) ->
                      let f = map_key field in
                      let aggs = aggs_all |> List.filter (fun a -> let la = String.lowercase_ascii (String.trim a) in not (String.length la >= 5 && String.sub la 0 5 = "topk(")) in
                      let base_sel = [f; "count() AS cnt"] in
                      let full_sel = base_sel @ aggs in
                      (full_sel, (f :: bys) |> List.sort_uniq String.compare, Some [ ("cnt", Desc) ], Some n)
                  | None -> (aggs_all, bys, q.sort, None)
                )
            in
            (* window bucketing *)
            let (sel, gb, ob) =
              match q.window with
              | None -> (sel0, gb0, ob0)
              | Some w ->
                  let ts_field = Entity_mapping.get_timestamp_field ent in
                  let n_str = String.sub w 0 (String.length w - 1) in
                  let unit = String.sub w (String.length w - 1) 1 in
                  let n = match int_of_string_opt n_str with Some n -> n | None -> 1 in
                  let unit_sql = match String.lowercase_ascii unit with | "m" -> "MINUTE" | "h" -> "HOUR" | "d" -> "DAY" | _ -> "MINUTE" in
                  let bucket_expr = Printf.sprintf "toStartOfInterval(%s, INTERVAL %d %s) AS _window" ts_field n unit_sql in
                  let sel' = sel0 @ [bucket_expr] in
                  let gb' = gb0 @ ["_window"] in
                  let ob' = match ob0 with Some srt -> Some srt | None -> Some [ ("_window", Asc) ] in
                  (sel', gb', ob')
            in
            let limit' = match (lim0, limit) with | (Some n, Some m) -> Some (min n m) | (Some n, None) -> Some n | (None, l) -> l in
            (Some sel, (if gb = [] then None else Some gb), ob, limit')
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
