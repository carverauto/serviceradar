(* file: srql/bin/main.ml *)

module StringCI = struct
  type t = string

  let compare = String.compare
end

module StringSet = Set.Make (StringCI)

let getenv name default = match Sys.getenv_opt name with Some v -> v | None -> default

let getenv_bool name default =
  match Sys.getenv_opt name with
  | Some v -> (
      let v = String.lowercase_ascii (String.trim v) in
      match v with
      | "1" | "true" | "yes" | "y" -> true
      | "0" | "false" | "no" | "n" -> false
      | _ -> default)
  | None -> default

let getenv_int name default =
  match Sys.getenv_opt name with
  | Some v -> ( try int_of_string (String.trim v) with _ -> default)
  | None -> default

let config_from_env () =
  let host = getenv "PROTON_HOST" "localhost" in
  let port = getenv_int "PROTON_PORT" 8463 in
  let database = getenv "PROTON_DB" "default" in
  let username = getenv "PROTON_USER" "default" in
  let password = getenv "PROTON_PASSWORD" "" in
  let use_tls = getenv_bool "PROTON_TLS" false in
  let verify_hostname = getenv_bool "PROTON_VERIFY_HOSTNAME" true in
  let insecure_skip_verify = getenv_bool "PROTON_INSECURE_SKIP_VERIFY" false in
  let compression =
    match getenv "PROTON_COMPRESSION" "lz4" |> String.lowercase_ascii with
    | "none" | "off" | "0" -> None
    | _ -> Some Proton.Compress.LZ4
  in
  Srql_translator.Proton_client.Config.
    {
      host;
      port;
      database;
      username;
      password;
      use_tls;
      ca_cert = Sys.getenv_opt "PROTON_CA_CERT";
      client_cert = Sys.getenv_opt "PROTON_CLIENT_CERT";
      client_key = Sys.getenv_opt "PROTON_CLIENT_KEY";
      verify_hostname;
      insecure_skip_verify;
      compression;
      settings = [];
    }

(* RFC3339 and row helpers moved to Srql_translator.Json_conv *)

(* Pagination helpers *)
type dir = Next | Prev

let params_to_json (params : (string * Proton.Column.value) list) : Yojson.Safe.t =
  `List
    (List.map
       (fun (name, value) ->
         `Assoc [ ("name", `String name); ("value", `String (Proton.Column.value_to_string value)) ])
       params)

let inline_sql sql params = Srql_translator.Proton_client.Client.substitute_params sql params

let default_order_for_entity (entity : string) : (string * Srql_translator.Sql_ir.order_dir) list =
  let ts = Srql_translator.Entity_mapping.get_timestamp_field entity in
  [ (ts, Srql_translator.Sql_ir.Desc) ]

let index_of_sub (s : string) (sub : string) : int option =
  let ls = String.length s and lsub = String.length sub in
  let rec loop i =
    if i + lsub > ls then None else if String.sub s i lsub = sub then Some i else loop (i + 1)
  in
  loop 0

let escape_sql_string (s : string) =
  let b = Buffer.create (String.length s + 8) in
  String.iter (fun c -> if c = '\'' then Buffer.add_string b "''" else Buffer.add_char b c) s;
  Buffer.contents b

(* Build SQL literal from a typed cursor value *)
let sql_literal_of_typed (typ : string) value : string =
  match value with
  | Proton.Column.String s ->
      let lt = String.lowercase_ascii typ in
      let has needle = match index_of_sub lt needle with Some _ -> true | None -> false in
      if has "string" || has "uuid" then "'" ^ escape_sql_string s ^ "'" else s
  | Proton.Column.DateTime (ts, _tz) -> Printf.sprintf "toDateTime(%Ld)" ts
  | Proton.Column.DateTime64 (v, p, _tz) -> Printf.sprintf "toDateTime64(%Ld, %d)" v p
  | _ -> Proton.Column.value_to_string value

(* Build a lexicographic boundary predicate for multi-column ORDER BY. 
   order: (field, dir) list
   vals: Each is (name, typ, value) coming from the row/columns
   direction: Next|Prev
*)
let build_boundary_predicate ~(order : (string * Srql_translator.Sql_ir.order_dir) list)
    ~(vals : (string * string * _) list) ~(direction : dir) : string option =
  if order = [] then None
  else
    (* Map value lookup by field name *)
    let lookup name =
      try Some (List.find (fun (n, _, _) -> String.equal n name) vals) with Not_found -> None
    in
    (* ensure all keys present *)
    if List.exists (fun (f, _) -> lookup f = None) order then None
    else
      let rec build_terms idx acc_eq =
        match List.nth order idx with
        | exception _ -> []
        | field, odir ->
            let _, typ, v = Option.get (lookup field) in
            let lit = sql_literal_of_typed typ v in
            let cmp =
              match (odir, direction) with
              | Srql_translator.Sql_ir.Asc, Next | Srql_translator.Sql_ir.Desc, Prev -> ">"
              | Srql_translator.Sql_ir.Desc, Next | Srql_translator.Sql_ir.Asc, Prev -> "<"
            in
            let this_term =
              let lhs = field and rhs = lit in
              let cmp_expr = Printf.sprintf "%s %s %s" lhs cmp rhs in
              match acc_eq with
              | [] -> cmp_expr
              | eqs -> "(" ^ String.concat " AND " eqs ^ ") AND " ^ cmp_expr
            in
            this_term :: build_terms (idx + 1) (acc_eq @ [ Printf.sprintf "%s = %s" field lit ])
      in
      let terms = build_terms 0 [] in
      if terms = [] then None
      else Some ("(" ^ String.concat " OR " (List.map (fun t -> "(" ^ t ^ ")") terms) ^ ")")

let splice_where_predicate (sql : string) (predicate : string) : string =
  let lsql = String.lowercase_ascii sql in
  let pos_order =
    match index_of_sub lsql " order by " with Some i -> i | None -> String.length sql
  in
  let head = String.sub sql 0 pos_order in
  let tail = String.sub sql pos_order (String.length sql - pos_order) in
  let lhead = String.lowercase_ascii head in
  let new_head =
    match index_of_sub lhead " where " with
    | Some _ -> head ^ " AND (" ^ predicate ^ ")"
    | None -> head ^ " WHERE " ^ predicate
  in
  new_head ^ tail

let parse_to_ast (query_str : string) : Srql_translator.Sql_ir.query =
  (* New default: ASQ syntax is primary. No SRQL fallback. *)
  let qspec = Srql_translator.Query_parser.parse query_str in
  match Srql_translator.Query_planner.plan_to_srql qspec with
  | Some ast -> (
      match Srql_translator.Query_validator.validate ast with
      | Ok () -> ast
      | Error msg -> failwith msg)
  | None -> failwith "Query planning failed: please provide in:<entity> and attribute filters"

let () =
  let interface = getenv "SRQL_LISTEN_HOST" "0.0.0.0" in
  let port = getenv_int "SRQL_LISTEN_PORT" 8080 in
  Dream.run ~interface ~port @@ Dream.logger
  @@ Dream.router
       [
         (* Translate-only endpoint, kept as-is *)
         Dream.post "/translate" (fun request ->
             let%lwt body = Dream.body request in
             try
               let json = Yojson.Safe.from_string body in
               let query_str = Yojson.Safe.Util.(json |> member "query" |> to_string) in
               (* Mode selection: header overrides body; stream|snapshot|auto *)
               let bounded_mode =
                 match Dream.header request "X-SRQL-Mode" with
                 | Some s -> String.lowercase_ascii (String.trim s)
                 | None -> (
                     let open Yojson.Safe.Util in
                     match json |> member "bounded_mode" with
                     | `String s -> String.lowercase_ascii (String.trim s)
                     | _ -> (
                         match json |> member "bounded" with
                         | `Bool true -> "bounded"
                         | `Bool false -> "unbounded"
                         | _ -> "auto"))
               in
               (* Parse new OCSF-aligned query syntax and translate *)
               try
                 let ast = parse_to_ast query_str in
                 let translation = Srql_translator.Translator.translate_query ast in
                 let sql = inline_sql translation.sql translation.params in
                 let base_fields = [ ("sql", `String sql); ("hint", `String bounded_mode) ] in
                 let fields =
                   if translation.params = [] then base_fields
                   else base_fields @ [ ("params", params_to_json translation.params) ]
                 in
                 `Assoc fields |> Yojson.Safe.to_string |> Dream.json
               with
               | Failure msg ->
                   `Assoc [ ("error", `String msg) ]
                   |> Yojson.Safe.to_string |> Dream.json ~status:`Bad_Request
               | ex ->
                   `Assoc [ ("error", `String (Printexc.to_string ex)) ]
                   |> Yojson.Safe.to_string |> Dream.json ~status:`Bad_Request
             with
             | Yojson.Safe.Util.Type_error (msg, _) ->
                 `Assoc [ ("error", `String ("Invalid JSON body: " ^ msg)) ]
                 |> Yojson.Safe.to_string |> Dream.json ~status:`Bad_Request
             | Not_found ->
                 `Assoc [ ("error", `String "Invalid JSON body: missing 'query' field") ]
                 |> Yojson.Safe.to_string |> Dream.json ~status:`Bad_Request
             | Yojson.Json_error msg ->
                 `Assoc [ ("error", `String ("JSON parsing error: " ^ msg)) ]
                 |> Yojson.Safe.to_string |> Dream.json ~status:`Bad_Request);
         (* WebSocket streaming endpoint: /api/stream?query=... *)
         Dream.get "/api/stream" (fun request ->
             (* Origin check parity: SRQL_ALLOWED_ORIGINS=csv or allow all by default *)
             let origin_allowed =
               match Dream.header request "Origin" with
               | None -> true
               | Some origin -> (
                   match Sys.getenv_opt "SRQL_ALLOWED_ORIGINS" with
                   | None -> true
                   | Some csv ->
                       let allowed =
                         csv |> String.split_on_char ',' |> List.map String.trim
                         |> List.filter (( <> ) "")
                       in
                       List.exists (fun a -> a = origin || a = "*") allowed)
             in
             if not origin_allowed then
               Dream.json ~status:`Forbidden
                 (Yojson.Safe.to_string
                    (`Assoc [ ("error", `String "WebSocket CORS: Origin not allowed") ]))
             else
               (* API key / bearer parity: require API key if SRQL_API_KEY set; optionally require Bearer if SRQL_REQUIRE_BEARER=true *)
               let api_key_ok =
                 match Sys.getenv_opt "SRQL_API_KEY" with
                 | None -> true
                 | Some needed_key -> (
                     let provided =
                       match Dream.header request "X-API-Key" with
                       | Some v -> Some v
                       | None -> (
                           match Dream.cookie request "api_key" with
                           | Some v -> Some v
                           | None -> None)
                     in
                     match provided with Some v -> v = needed_key | None -> false)
               in
               let bearer_required =
                 match Sys.getenv_opt "SRQL_REQUIRE_BEARER" with
                 | Some v ->
                     let v = String.lowercase_ascii (String.trim v) in
                     v = "1" || v = "true" || v = "yes"
                 | None -> false
               in
               let bearer_ok =
                 match Dream.header request "Authorization" with
                 | Some s when String.length s > 7 && String.sub s 0 7 = "Bearer " -> true
                 | _ -> not bearer_required
               in
               if (not api_key_ok) || not bearer_ok then
                 Dream.json ~status:`Unauthorized
                   (Yojson.Safe.to_string (`Assoc [ ("error", `String "Unauthorized WebSocket") ]))
               else
                 match Dream.query request "query" with
                 | None ->
                     Dream.json ~status:`Bad_Request
                       (Yojson.Safe.to_string
                          (`Assoc [ ("error", `String "Missing query parameter") ]))
                 | Some query_str ->
                     (* Always treat WebSocket as streaming mode regardless of header/body *)
                     let sql_stream_translation =
                       try
                         let ast0 = parse_to_ast query_str in
                         let ast = { ast0 with q_type = `Stream; limit = None } in
                         Srql_translator.Translator.translate_query ast
                       with ex -> raise ex
                     in
                     let sql_stream = sql_stream_translation.sql in
                     let stream_params = sql_stream_translation.params in
                     (* Small helpers for RFC3339 timestamps *)
                     let power10 p =
                       let rec loop acc i =
                         if i = 0 then acc else loop (Int64.mul acc 10L) (i - 1)
                       in
                       loop 1L p
                     in
                     let rfc3339_of_datetime ts =
                       let tm = Unix.gmtime (Int64.to_float ts) in
                       Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
                         (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
                         tm.Unix.tm_sec
                     in
                     let rfc3339_of_datetime64 v precision =
                       let denom = power10 precision in
                       let secs = Int64.div v denom in
                       rfc3339_of_datetime secs
                     in
                     let rfc3339_now () =
                       let tm = Unix.gmtime (Unix.gettimeofday ()) in
                       Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
                         (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
                         tm.Unix.tm_sec
                     in
                     Dream.websocket (fun ws ->
                         let open Lwt.Syntax in
                         let cfg0 = config_from_env () in
                         let cfg =
                           Srql_translator.Proton_client.Config.
                             { cfg0 with settings = ("wait_end_of_query", "0") :: cfg0.settings }
                         in
                         let stop = ref false in
                         (* lightweight ping loop as JSON ping messages *)
                         let rec ping_loop () =
                           if !stop then Lwt.return_unit
                           else
                             let* () = Lwt_unix.sleep 45.0 in
                             let now = rfc3339_now () in
                             let* (_ : unit) =
                               Lwt.catch
                                 (fun () ->
                                   Dream.send ws
                                     (Yojson.Safe.to_string
                                        (`Assoc
                                           [ ("type", `String "ping"); ("timestamp", `String now) ])))
                                 (fun _ ->
                                   stop := true;
                                   Lwt.return_unit)
                             in
                             ping_loop ()
                         in
                         Lwt.async ping_loop;
                         let* () =
                           Lwt.catch
                             (fun () ->
                               Srql_translator.Proton_client.Client.with_connection cfg
                                 (fun client ->
                                   let sent_header = ref false in
                                   let send_json obj = Dream.send ws (Yojson.Safe.to_string obj) in
                                   let stmt = Proton.Client.prepare client sql_stream in
                                   let* _ =
                                     Proton.Client.query_iter_with_columns_prepared client stmt
                                       ~params:stream_params ~f:(fun row columns ->
                                         let now = rfc3339_now () in
                                         let* () =
                                           if not !sent_header then (
                                             let cols_json =
                                               `List
                                                 (List.map
                                                    (fun (n, t) ->
                                                      `Assoc
                                                        [ ("name", `String n); ("type", `String t) ])
                                                    columns)
                                             in
                                             let header_msg =
                                               `Assoc
                                                 [
                                                   ("type", `String "columns");
                                                   ("columns", cols_json);
                                                   ("timestamp", `String now);
                                                 ]
                                             in
                                             let* () = send_json header_msg in
                                             sent_header := true;
                                             Lwt.return_unit)
                                           else Lwt.return_unit
                                         in
                                         let row_obj =
                                           let json_of_cell (_typ : string)
                                               (v : Proton.Column.value) : Yojson.Safe.t =
                                             match v with
                                             | Proton.Column.Null -> `Null
                                             | Proton.Column.DateTime (ts, _) ->
                                                 `String (rfc3339_of_datetime ts)
                                             | Proton.Column.DateTime64 (vv, p, _) ->
                                                 `String (rfc3339_of_datetime64 vv p)
                                             | _ -> `String (Proton.Column.value_to_string v)
                                           in
                                           let kvs =
                                             List.map2
                                               (fun (name, typ) v -> (name, json_of_cell typ v))
                                               columns row
                                           in
                                           `Assoc kvs
                                         in
                                         let msg =
                                           `Assoc
                                             [
                                               ("type", `String "data");
                                               ("data", row_obj);
                                               ("timestamp", `String now);
                                             ]
                                         in
                                         let* () = send_json msg in
                                         Lwt.return_unit)
                                   in
                                   let now = rfc3339_now () in
                                   let* () =
                                     Dream.send ws
                                       (Yojson.Safe.to_string
                                          (`Assoc
                                             [
                                               ("type", `String "complete");
                                               ("timestamp", `String now);
                                             ]))
                                   in
                                   stop := true;
                                   Lwt.return_unit))
                             (fun exn ->
                               stop := true;
                               let now = rfc3339_now () in
                               let err = Printexc.to_string exn in
                               let* (_ : unit) =
                                 Lwt.catch
                                   (fun () ->
                                     Dream.send ws
                                       (Yojson.Safe.to_string
                                          (`Assoc
                                             [
                                               ("type", `String "error");
                                               ("error", `String err);
                                               ("timestamp", `String now);
                                             ])))
                                   (fun _ -> Lwt.return_unit)
                               in
                               Lwt.return_unit)
                         in
                         Lwt.return_unit));
         (* Main query execution endpoint (SRQL, ASQ-aligned syntax) *)
         Dream.post "/api/query" (fun request ->
             let%lwt body = Dream.body request in
             try
               let json = Yojson.Safe.from_string body in
               let open Yojson.Safe.Util in
               let query_str = json |> member "query" |> to_string in
               let direction =
                 match json |> member "direction" with
                 | `String s when String.lowercase_ascii s = "prev" -> Prev
                 | _ -> Next
               in
               let cursor = match json |> member "cursor" with `String s -> Some s | _ -> None in
               let req_limit = match json |> member "limit" with `Int n -> Some n | _ -> None in
               (* Streaming mode via header or JSON body.
           Header takes precedence: X-SRQL-Mode: stream|snapshot|auto
           Body fallbacks: { mode: "stream|snapshot|auto" } OR { bounded_mode: "unbounded|bounded|auto" } OR { bounded: bool } *)
               let mode =
                 match Dream.header request "X-SRQL-Mode" with
                 | Some s -> (
                     match String.lowercase_ascii (String.trim s) with
                     | "stream" -> `Stream
                     | "snapshot" -> `Snapshot
                     | _ -> `Auto)
                 | None -> (
                     match json |> member "mode" with
                     | `String s -> (
                         match String.lowercase_ascii (String.trim s) with
                         | "stream" -> `Stream
                         | "snapshot" -> `Snapshot
                         | _ -> `Auto)
                     | _ -> (
                         match json |> member "bounded_mode" with
                         | `String s -> (
                             match String.lowercase_ascii (String.trim s) with
                             | "unbounded" -> `Stream
                             | "bounded" -> `Snapshot
                             | _ -> `Auto)
                         | _ -> (
                             match json |> member "bounded" with
                             | `Bool true -> `Snapshot
                             | `Bool false -> `Stream
                             | _ -> `Auto)))
               in

               (* Configure default time window via header if provided *)
               (match Dream.header request "X-SRQL-Default-Time" with
               | Some s when String.trim s <> "" ->
                   let trimmed = String.trim s in
                   Srql_translator.Query_planner.set_default_time (Some trimmed)
               | _ -> Srql_translator.Query_planner.set_default_time None);
               let wrap_from_with_table sql =
                 let lsql = String.lowercase_ascii sql in
                 let contains s sub =
                   let len_s = String.length s and len_sub = String.length sub in
                   let rec loop i =
                     if i + len_sub > len_s then false
                     else if String.sub s i len_sub = sub then true
                     else loop (i + 1)
                   in
                   loop 0
                 in
                 let has_from = contains lsql " from " in
                 let has_table_wrapper = contains lsql " from table(" in
                 if (not has_from) || has_table_wrapper then sql
                 else
                   try
                     let lfrom = " from " in
                     let idx_from =
                       let rec find_from i =
                         if i >= String.length lsql then raise Not_found
                         else if String.sub lsql i (String.length lfrom) = lfrom then i
                         else find_from (i + 1)
                       in
                       find_from 0
                     in
                     let start_tbl = idx_from + String.length lfrom in
                     let rec skip_spaces j =
                       if j < String.length lsql && lsql.[j] = ' ' then skip_spaces (j + 1) else j
                     in
                     let tbl_start = skip_spaces start_tbl in
                     let keywords =
                       [ " where "; " limit "; " group "; " order "; " settings "; " union " ]
                     in
                     let next_kw_pos =
                       List.filter_map
                         (fun kw ->
                           let rec find i =
                             if i >= String.length lsql then None
                             else if String.sub lsql i (String.length kw) = kw then Some i
                             else find (i + 1)
                           in
                           find tbl_start)
                         keywords
                       |> List.sort compare
                       |> function
                       | x :: _ -> x
                       | [] -> String.length lsql
                     in
                     let tbl_end = next_kw_pos in
                     let before = String.sub sql 0 tbl_start in
                     let tbl = String.sub sql tbl_start (tbl_end - tbl_start) |> String.trim in
                     let after = String.sub sql tbl_end (String.length sql - tbl_end) in
                     before ^ "table(" ^ tbl ^ ")" ^ after
                   with _ -> sql
               in
               (* Parse SRQL (new syntax) *)
               let ast0 = parse_to_ast query_str in
               let has_aggregates =
                 match ast0.select_fields with
                 | Some fields ->
                     List.exists
                       (fun f ->
                         let trimmed = String.trim f in
                         String.contains trimmed '(')
                       fields
                 | None -> false
               in
               let order_opt =
                 match ast0.order_by with
                 | Some o when o <> [] -> Some o
                 | _ when has_aggregates -> None
                 | _ -> Some (default_order_for_entity ast0.entity)
               in
               let limit_eff = match req_limit with Some n -> Some n | None -> ast0.limit in
               (* Auto currently prefers snapshot unless query planner marks streaming explicitly in future.
          We can enhance this later to detect stream-safe queries. *)
               let q_type = match mode with `Stream -> `Stream | _ -> `Select in
               let ast = { ast0 with order_by = order_opt; limit = limit_eff; q_type } in

               (* Ensure SELECT includes ORDER BY fields for stable pagination *)
               let ast, added_fields =
                 match (ast.q_type, ast.select_fields, order_opt) with
                 | `Select, Some fields, Some order
                   when not (List.length fields = 1 && List.hd fields = "*") ->
                     let collect_names acc f =
                       let lower = String.lowercase_ascii f in
                       match index_of_sub lower " as " with
                       | Some i ->
                           let base = String.sub f 0 i |> String.trim in
                           let alias_start = i + 4 in
                           let alias =
                             String.sub f alias_start (String.length f - alias_start) |> String.trim
                           in
                           let add name set =
                             if name = "" then set
                             else StringSet.add (String.lowercase_ascii name) set
                           in
                           acc |> add base |> add alias
                       | None ->
                           if f = "" then acc else StringSet.add (String.lowercase_ascii f) acc
                     in
                     let present_set = List.fold_left collect_names StringSet.empty fields in
                     let missing =
                       order |> List.map fst
                       |> List.filter (fun f ->
                              not (StringSet.mem (String.lowercase_ascii f) present_set))
                     in
                     if missing = [] then (ast, [])
                     else ({ ast with select_fields = Some (fields @ missing) }, missing)
                 | _ -> (ast, [])
               in

               (* Build SQL and apply cursor boundary if provided *)
               let translation = Srql_translator.Translator.translate_query ast in
               let base_sql = translation.sql in
               let base_params = translation.params in
               let sql_with_boundary =
                 match (cursor, order_opt) with
                 | None, _ -> base_sql
                 | Some _, None -> base_sql
                 | Some _, Some order -> (
                     try
                       let open Yojson.Safe.Util in
                       let decode_cursor s =
                         try Yojson.Safe.from_string s
                         with _ ->
                           let rev_tbl = Array.make 256 (-1) in
                           let chars =
                             "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
                           in
                           String.iteri (fun i c -> rev_tbl.(int_of_char c) <- i) chars;
                           let len = String.length s in
                           let buf = Buffer.create len in
                           let rec sextet i acc bits =
                             if i >= len then (acc, bits, i)
                             else
                               let c = s.[i] in
                               if c = '=' then (acc, bits, i + 1)
                               else
                                 let v = rev_tbl.(int_of_char c) in
                                 if v < 0 then (acc, bits, i + 1)
                                 else
                                   let acc' = (acc lsl 6) lor v in
                                   sextet (i + 1) acc' (bits + 6)
                           in
                           let rec loop i acc bits =
                             if i >= len then ()
                             else
                               let acc', bits', j = sextet i acc bits in
                               if bits' >= 8 then (
                                 let b = (acc' lsr (bits' - 8)) land 0xFF in
                                 Buffer.add_char buf (char_of_int b);
                                 loop j acc' (bits' - 8))
                               else loop j acc' bits'
                           in
                           loop 0 0 0;
                           Yojson.Safe.from_string (Buffer.contents buf)
                       in
                       let cjson = match cursor with Some s -> decode_cursor s | None -> `Null in
                       let order_from_cursor =
                         cjson |> member "order" |> to_list
                         |> List.map (fun o ->
                                let f = o |> member "field" |> to_string in
                                let d = o |> member "dir" |> to_string |> String.lowercase_ascii in
                                ( f,
                                  if d = "desc" then Srql_translator.Sql_ir.Desc
                                  else Srql_translator.Sql_ir.Asc ))
                       in
                       let order_used =
                         if order_from_cursor = [] then order else order_from_cursor
                       in
                       let vals =
                         cjson |> member "values" |> to_list
                         |> List.filter_map (fun v ->
                                try
                                  let name = v |> member "name" |> to_string in
                                  let typ = v |> member "typ" |> to_string in
                                  let kind = v |> member "k" |> to_string in
                                  let value = v |> member "v" |> to_string in
                                  match kind with
                                  | "s" -> Some (name, typ, Proton.Column.String value)
                                  | "n" -> Some (name, typ, Proton.Column.String value)
                                  | "dt" ->
                                      Some
                                        ( name,
                                          typ,
                                          Proton.Column.DateTime (Int64.of_string value, None) )
                                  | "dt64" ->
                                      let prec = v |> member "p" |> to_int in
                                      Some
                                        ( name,
                                          typ,
                                          Proton.Column.DateTime64
                                            (Int64.of_string value, prec, None) )
                                  | _ -> None
                                with _ -> None)
                       in
                       match build_boundary_predicate ~order:order_used ~vals ~direction with
                       | None -> base_sql
                       | Some pred -> splice_where_predicate base_sql pred
                     with _ -> base_sql)
               in
               let sql_with_boundary =
                 match q_type with
                 | `Stream -> sql_with_boundary
                 | _ -> wrap_from_with_table sql_with_boundary
               in

               let cfg = config_from_env () in
               let%lwt raw_result =
                 Srql_translator.Proton_client.Client.with_connection cfg (fun client ->
                     Srql_translator.Proton_client.Client.execute_with_params client
                       sql_with_boundary ~params:base_params)
               in

               (* Maybe reverse rows for prev direction to retain original ordering *)
               let result =
                 match (direction, raw_result) with
                 | Prev, Proton.Client.Rows (rows, cols) -> Proton.Client.Rows (List.rev rows, cols)
                 | _ -> raw_result
               in

               (* Prepare cursors if possible *)
               let next_cursor, prev_cursor, limit_meta =
                 match (result, order_opt, limit_eff) with
                 | Proton.Client.Rows (rows, cols), Some (_ :: _ as ord), Some lim
                   when List.length rows = lim -> (
                     let name_to_index =
                       let tbl = Hashtbl.create (List.length cols) in
                       List.iteri (fun i (n, t) -> Hashtbl.add tbl n (i, t)) cols;
                       tbl
                     in
                     let extract_values row =
                       List.filter_map
                         (fun (f, _d) ->
                           match Hashtbl.find_opt name_to_index f with
                           | Some (idx, typ) -> (
                               try Some (f, typ, List.nth row idx) with _ -> None)
                           | None -> None)
                         ord
                     in
                     let first_values = match rows with r :: _ -> extract_values r | _ -> [] in
                     let last_values =
                       match List.rev rows with r :: _ -> extract_values r | _ -> []
                     in
                     let encode_value (name, typ, v) =
                       match v with
                       | Proton.Column.DateTime (ts, _tz) ->
                           `Assoc
                             [
                               ("name", `String name);
                               ("typ", `String typ);
                               ("k", `String "dt");
                               ("v", `String (Int64.to_string ts));
                             ]
                       | Proton.Column.DateTime64 (vv, p, _tz) ->
                           `Assoc
                             [
                               ("name", `String name);
                               ("typ", `String typ);
                               ("k", `String "dt64");
                               ("v", `String (Int64.to_string vv));
                               ("p", `Int p);
                             ]
                       | Proton.Column.String s ->
                           `Assoc
                             [
                               ("name", `String name);
                               ("typ", `String typ);
                               ("k", `String "s");
                               ("v", `String s);
                             ]
                       | _ ->
                           `Assoc
                             [
                               ("name", `String name);
                               ("typ", `String typ);
                               ("k", `String "n");
                               ("v", `String (Proton.Column.value_to_string v));
                             ]
                     in
                     let encode_cursor vals =
                       `Assoc
                         [
                           ( "order",
                             `List
                               (List.map
                                  (fun (f, d) ->
                                    `Assoc
                                      [
                                        ("field", `String f);
                                        ( "dir",
                                          `String
                                            (match d with
                                            | Srql_translator.Sql_ir.Asc -> "asc"
                                            | Srql_translator.Sql_ir.Desc -> "desc") );
                                      ])
                                  ord) );
                           ("values", `List (List.map encode_value vals));
                         ]
                       |> Yojson.Safe.to_string
                     in
                     let next_cur = encode_cursor last_values in
                     let prev_cur = encode_cursor first_values in
                     ( Some (`String next_cur),
                       Some (`String prev_cur),
                       match limit_eff with Some n -> `Int n | None -> `Null ))
                 | _ -> (None, None, match limit_eff with Some n -> `Int n | None -> `Null)
               in

               let results_json =
                 match result with
                 | Proton.Client.NoRows -> `List []
                 | Proton.Client.Rows (rows, cols) ->
                     Srql_translator.Json_conv.rows_to_json ~drop_cols:added_fields (rows, cols)
               in
               (* Encode cursors as base64 of JSON for transport stability *)
               let b64_encode s =
                 (* Simple base64 implementation for small strings *)
                 let tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
                 let len = String.length s in
                 let buf = Buffer.create ((len + 2) / 3 * 4) in
                 let get i = int_of_char s.[i] in
                 let rec loop i =
                   if i >= len then ()
                   else
                     let b0 = get i in
                     let b1 = if i + 1 < len then get (i + 1) else 0 in
                     let b2 = if i + 2 < len then get (i + 2) else 0 in
                     let n = (b0 lsl 16) lor (b1 lsl 8) lor b2 in
                     let c0 = (n lsr 18) land 0x3F
                     and c1 = (n lsr 12) land 0x3F
                     and c2 = (n lsr 6) land 0x3F
                     and c3 = n land 0x3F in
                     Buffer.add_char buf tbl.[c0];
                     Buffer.add_char buf tbl.[c1];
                     if i + 1 < len then Buffer.add_char buf tbl.[c2] else Buffer.add_char buf '=';
                     if i + 2 < len then Buffer.add_char buf tbl.[c3] else Buffer.add_char buf '=';
                     loop (i + 3)
                 in
                 loop 0;
                 Buffer.contents buf
               in
               let encode_cursor_b64 = function
                 | None -> `Null
                 | Some (`String s) -> `String (b64_encode s)
                 | Some other -> other
               in

               let response =
                 `Assoc
                   [
                     ("results", results_json);
                     ( "pagination",
                       `Assoc
                         [
                           ("next_cursor", encode_cursor_b64 next_cursor);
                           ("prev_cursor", encode_cursor_b64 prev_cursor);
                           ("limit", limit_meta);
                         ] );
                     ("error", `Null);
                   ]
               in
               Dream.json (Yojson.Safe.to_string response)
             with
             | Failure msg ->
                 let err =
                   `Assoc
                     [
                       ("results", `List []);
                       ( "pagination",
                         `Assoc [ ("next_cursor", `Null); ("prev_cursor", `Null); ("limit", `Null) ]
                       );
                       ("error", `String ("Invalid SRQL query: " ^ msg));
                     ]
                 in
                 Dream.json ~status:`Bad_Request (Yojson.Safe.to_string err)
             | Yojson.Safe.Util.Type_error (msg, _) ->
                 let err =
                   `Assoc
                     [
                       ("results", `List []);
                       ( "pagination",
                         `Assoc [ ("next_cursor", `Null); ("prev_cursor", `Null); ("limit", `Null) ]
                       );
                       ("error", `String ("Invalid JSON body: " ^ msg));
                     ]
                 in
                 Dream.json ~status:`Bad_Request (Yojson.Safe.to_string err)
             | Not_found ->
                 let err =
                   `Assoc
                     [
                       ("results", `List []);
                       ( "pagination",
                         `Assoc [ ("next_cursor", `Null); ("prev_cursor", `Null); ("limit", `Null) ]
                       );
                       ("error", `String "Invalid JSON body: missing 'query' field");
                     ]
                 in
                 Dream.json ~status:`Bad_Request (Yojson.Safe.to_string err)
             | Yojson.Json_error msg ->
                 let err =
                   `Assoc
                     [
                       ("results", `List []);
                       ( "pagination",
                         `Assoc [ ("next_cursor", `Null); ("prev_cursor", `Null); ("limit", `Null) ]
                       );
                       ("error", `String ("JSON parsing error: " ^ msg));
                     ]
                 in
                 Dream.json ~status:`Bad_Request (Yojson.Safe.to_string err));
         Dream.get "/health" (fun _ -> Dream.json "{ \"status\": \"ok\" }");
       ]
