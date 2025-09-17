open Lwt.Syntax

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

let is_raw_sql s =
  let ls = String.lowercase_ascii (String.trim s) in
  let starts_with pref =
    let lp = String.length pref in
    String.length ls >= lp && String.sub ls 0 lp = pref
  in
  starts_with "select " || starts_with "show " || starts_with "with " || starts_with "describe "
  || starts_with "explain "

let () =
  (* Parse CLI flags; support --stream, --translate-only and query as remaining args *)
  let args = Array.to_list Sys.argv |> List.tl in
  let streaming_cli = List.exists (fun a -> a = "--stream") args in
  let translate_only = List.exists (fun a -> a = "--translate-only") args in
  let query_args = args |> List.filter (fun a -> a <> "--stream" && a <> "--translate-only") in
  let query =
    match query_args with [] -> "in:devices limit:10" | _ -> String.concat " " query_args
  in

  Printf.printf "Live SRQL Runner (ASQ-aligned)\n";
  Printf.printf "=================================\n\n";
  Printf.printf "Query: %s\n" query;
  if translate_only then Printf.printf "(translate-only)\n";

  (* Build config from environment *)
  let host = getenv "PROTON_HOST" "localhost" in
  let port = getenv_int "PROTON_PORT" 9440 in
  let database = getenv "PROTON_DB" "default" in
  let username = getenv "PROTON_USER" "default" in
  let password = getenv "PROTON_PASSWORD" "" in
  let use_tls = getenv_bool "PROTON_TLS" true in
  let insecure_skip_verify = getenv_bool "PROTON_INSECURE_SKIP_VERIFY" true in
  let verify_hostname = getenv_bool "PROTON_VERIFY_HOSTNAME" false in

  (* Compression: default to LZ4 unless explicitly disabled *)
  let compression =
    match getenv "PROTON_COMPRESSION" "lz4" |> String.lowercase_ascii with
    | "none" | "off" | "0" -> None
    | _ -> Some Proton.Compress.LZ4
  in

  let max_exec_time = getenv "SRQL_MAX_EXEC_TIME" "" |> String.trim in
  let settings =
    (* Enable Proton streaming behavior automatically when --stream is used, or via env override *)
    let base =
      if streaming_cli || getenv_bool "SRQL_STREAMING" false then [ ("wait_end_of_query", "0") ]
      else []
    in
    if max_exec_time <> "" then ("max_execution_time", max_exec_time) :: base else base
  in
  let config =
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
        settings;
      }
  in

  Printf.printf "Connecting: host=%s port=%d tls=%b db=%s user=%s compression=%s\n\n" host port
    use_tls database username
    (match compression with None -> "none" | Some _ -> "lz4");

  let run_native_once cfg =
    let base_sql, params =
      if is_raw_sql query then (query, [])
      else
        let t = Srql_translator.Proton_client.SRQL.translate query in
        (t.sql, t.params)
    in
    (* Boundedness control: SRQL_BOUNDED=bounded|unbounded|auto (default auto) *)
    let bounded_mode = getenv "SRQL_BOUNDED" "auto" |> String.lowercase_ascii in
    let contains s sub =
      let len_s = String.length s and len_sub = String.length sub in
      let rec loop i =
        if i + len_sub > len_s then false
        else if String.sub s i len_sub = sub then true
        else loop (i + 1)
      in
      loop 0
    in
    let wrap_table_if_needed ~stream sql =
      let lsql = String.lowercase_ascii sql in
      let has_table = contains lsql " from table(" in
      (* Policy: only stream when explicitly asked. Otherwise snapshot-wrap. *)
      let snapshot_requested =
        (not stream) && match bounded_mode with "unbounded" | "0" -> false | _ -> true
      in
      if stream then
        (* Unwrap table(...) and strip LIMIT for unbounded streaming *)
        let sql' =
          if has_table then
            try
              let lfrom_tbl = " from table(" in
              let idx =
                let rec find_from i =
                  if i >= String.length lsql then raise Not_found
                  else if String.sub lsql i (String.length lfrom_tbl) = lfrom_tbl then i
                  else find_from (i + 1)
                in
                find_from 0
              in
              let start_tbl = idx + String.length lfrom_tbl in
              (* find closing ")" of table( ... ) *)
              let rec find_close j depth =
                if j >= String.length lsql then String.length lsql
                else
                  let c = lsql.[j] in
                  if c = '(' then find_close (j + 1) (depth + 1)
                  else if c = ')' then if depth = 0 then j else find_close (j + 1) (depth - 1)
                  else find_close (j + 1) depth
              in
              let end_tbl = find_close start_tbl 0 in
              let before = String.sub sql 0 idx in
              let tbl = String.sub sql start_tbl (end_tbl - start_tbl) in
              let after = String.sub sql (end_tbl + 1) (String.length sql - end_tbl - 1) in
              before ^ " from " ^ tbl ^ after
            with _ -> sql
          else sql
        in
        (* strip LIMIT if present at top-level *)
        let lsql2 = String.lowercase_ascii sql' in
        let idx_limit =
          let key = " limit " in
          let rec find i =
            if i + String.length key > String.length lsql2 then None
            else if String.sub lsql2 i (String.length key) = key then Some i
            else find (i + 1)
          in
          find 0
        in
        match idx_limit with None -> sql' | Some i -> String.sub sql' 0 i
      else if (not snapshot_requested) || has_table then sql
      else
        (* Find FROM and extract table identifier, wrap with table(...) *)
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
          let keywords = [ " where "; " limit "; " group "; " order "; " settings "; " union " ] in
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
    let sql = wrap_table_if_needed ~stream:streaming_cli base_sql in
    let print_params () =
      match params with
      | [] -> ()
      | ps ->
          print_endline "Parameters:";
          List.iter
            (fun (name, value) ->
              Printf.printf "  %s -> %s\n" name (Proton.Column.value_to_string value))
            ps;
          print_newline ()
    in
    if translate_only then (
      Printf.printf "SQL: %s\n" sql;
      print_params ();
      exit 0);
    (* print SQL and run *)
    Printf.printf "SQL:  %s\n\n" sql;
    print_params ();
    Srql_translator.Proton_client.Client.with_connection cfg (fun client ->
        let power10 p =
          let rec loop acc i = if i = 0 then acc else loop (Int64.mul acc 10L) (i - 1) in
          loop 1L p
        in
        let pad_left s width =
          let len = String.length s in
          if len >= width then s else String.make (width - len) '0' ^ s
        in
        let iso8601_of_datetime ts tz_opt =
          let tm = Unix.gmtime (Int64.to_float ts) in
          let y = tm.Unix.tm_year + 1900 and mo = tm.Unix.tm_mon + 1 and d = tm.Unix.tm_mday in
          let hh = tm.Unix.tm_hour and mm = tm.Unix.tm_min and ss = tm.Unix.tm_sec in
          let base = Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" y mo d hh mm ss in
          match tz_opt with
          | Some tz when String.lowercase_ascii tz = "utc" -> base ^ "Z"
          | _ -> base
        in
        let iso8601_of_datetime64 v precision tz_opt =
          let denom = power10 precision in
          let secs = Int64.div v denom in
          let frac = Int64.to_int (Int64.rem v denom) in
          let base = iso8601_of_datetime secs tz_opt in
          if precision > 0 then
            base ^ "."
            ^ pad_left (string_of_int frac) precision
            ^ match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> "" | _ -> ""
          else base
        in
        let pretty_value typ v =
          let lt = String.lowercase_ascii (String.trim typ) in
          match (lt, v) with
          | "bool", Proton.Column.UInt32 i -> if Int32.to_int i = 0 then "false" else "true"
          | "bool", Proton.Column.Int32 i -> if Int32.to_int i = 0 then "false" else "true"
          | lt, Proton.Column.DateTime (ts, tz)
            when String.length lt >= 8 && String.sub lt 0 8 = "datetime" ->
              iso8601_of_datetime ts tz
          | lt, Proton.Column.DateTime64 (v, p, tz)
            when String.length lt >= 10 && String.sub lt 0 10 = "datetime64" ->
              iso8601_of_datetime64 v p tz
          | _, other -> Proton.Column.value_to_string other
        in

        if streaming_cli then (
          Printf.printf "Unbounded query detected; streaming via native protocol...\n";
          let printed_header = ref false in
          let* _cols =
            Proton.Client.query_iter_with_columns_with_params client sql ~params
              ~f:(fun row columns ->
                if not !printed_header then (
                  let col_count = List.length columns in
                  Printf.printf "Columns (%d): " col_count;
                  List.iter (fun (name, typ) -> Printf.printf "%s:%s " name typ) columns;
                  Printf.printf "\n";
                  printed_header := true);
                let values = List.map2 (fun (_, typ) v -> pretty_value typ v) columns row in
                Printf.printf "%s\n" (String.concat " | " values);
                flush stdout;
                Lwt.return_unit)
          in
          Lwt.return_unit)
        else
          let* result = Srql_translator.Proton_client.Client.execute_with_params client sql ~params in
          match result with
          | Proton.Client.NoRows ->
              Printf.printf "No rows returned.\n";
              Lwt.return_unit
          | Proton.Client.Rows (rows, columns) ->
              let power10 p =
                let rec loop acc i = if i = 0 then acc else loop (Int64.mul acc 10L) (i - 1) in
                loop 1L p
              in
              let pad_left s width =
                let len = String.length s in
                if len >= width then s else String.make (width - len) '0' ^ s
              in
              let iso8601_of_datetime ts tz_opt =
                let tm = Unix.gmtime (Int64.to_float ts) in
                let y = tm.Unix.tm_year + 1900
                and mo = tm.Unix.tm_mon + 1
                and d = tm.Unix.tm_mday in
                let hh = tm.Unix.tm_hour and mm = tm.Unix.tm_min and ss = tm.Unix.tm_sec in
                let base = Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" y mo d hh mm ss in
                match tz_opt with
                | Some tz when String.lowercase_ascii tz = "utc" -> base ^ "Z"
                | _ -> base
              in
              let iso8601_of_datetime64 v precision tz_opt =
                let denom = power10 precision in
                let secs = Int64.div v denom in
                let frac = Int64.to_int (Int64.rem v denom) in
                let base = iso8601_of_datetime secs tz_opt in
                if precision > 0 then
                  base ^ "."
                  ^ pad_left (string_of_int frac) precision
                  ^
                  match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> "" | _ -> ""
                else base
              in
              let pretty_value typ v =
                let lt = String.lowercase_ascii (String.trim typ) in
                match (lt, v) with
                | "bool", Proton.Column.UInt32 i -> if Int32.to_int i = 0 then "false" else "true"
                | "bool", Proton.Column.Int32 i -> if Int32.to_int i = 0 then "false" else "true"
                | lt, Proton.Column.DateTime (ts, tz)
                  when String.length lt >= 8 && String.sub lt 0 8 = "datetime" ->
                    iso8601_of_datetime ts tz
                | lt, Proton.Column.DateTime64 (v, p, tz)
                  when String.length lt >= 10 && String.sub lt 0 10 = "datetime64" ->
                    iso8601_of_datetime64 v p tz
                | _, other -> Proton.Column.value_to_string other
              in
              let col_count = List.length columns in
              Printf.printf "Columns (%d): " col_count;
              List.iter (fun (name, typ) -> Printf.printf "%s:%s " name typ) columns;
              Printf.printf "\n";
              List.iter
                (fun row ->
                  let values = List.map2 (fun (_, typ) v -> pretty_value typ v) columns row in
                  Printf.printf "%s\n" (String.concat " | " values))
                rows;
              Lwt.return_unit)
  in
  Lwt_main.run (run_native_once config)
