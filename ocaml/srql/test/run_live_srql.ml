open Lwt.Syntax

let getenv name default = match Sys.getenv_opt name with Some v -> v | None -> default

let getenv_bool name default =
  match Sys.getenv_opt name with
  | Some v ->
      let v = String.lowercase_ascii (String.trim v) in
      (match v with
       | "1" | "true" | "yes" | "y" -> true
       | "0" | "false" | "no" | "n" -> false
       | _ -> default)
  | None -> default

let getenv_int name default =
  match Sys.getenv_opt name with
  | Some v -> (try int_of_string (String.trim v) with _ -> default)
  | None -> default

let () =
  (* Parse CLI flags; support --stream and SRQL as remaining args *)
  let args = Array.to_list Sys.argv |> List.tl in
  let streaming_cli = List.exists (fun a -> a = "--stream") args in
  let _ = streaming_cli in
  let srql_args = List.filter (fun a -> a <> "--stream") args in
  let srql =
    match srql_args with
    | [] -> "SHOW devices LIMIT 10"
    | _ -> String.concat " " srql_args
  in

  Printf.printf "Live SRQL Runner\n";
  Printf.printf "=================\n\n";
  Printf.printf "SRQL: %s\n" srql;

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

  let config = Srql_translator.Proton_client.Config.{
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
    settings = (if getenv_bool "SRQL_STREAMING" false then [ ("wait_end_of_query", "0") ] else []);
  } in

  Printf.printf "Connecting: host=%s port=%d tls=%b db=%s user=%s compression=%s\n\n"
    host port use_tls database username (match compression with None -> "none" | Some _ -> "lz4");

  let run_native_once cfg =
    let original_sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
      (* Boundedness control: SRQL_BOUNDED=bounded|unbounded|auto (default auto) *)
      let bounded_mode = getenv "SRQL_BOUNDED" "auto" |> String.lowercase_ascii in
      let contains s sub =
        let len_s = String.length s and len_sub = String.length sub in
        let rec loop i = if i + len_sub > len_s then false else if String.sub s i len_sub = sub then true else loop (i+1) in
        loop 0
      in
      let wrap_table_if_needed sql =
        let lsql = String.lowercase_ascii sql in
        let has_limit = contains lsql " limit " in
        let has_table = contains lsql " from table(" in
        let should_wrap =
          match bounded_mode with
          | "bounded" | "1" -> true
          | "unbounded" | "0" -> false
          | _ (* auto *) -> has_limit && not has_table
        in
        if not should_wrap || has_table then sql
        else (
          (* Find FROM and extract table identifier, wrap with table(...) *)
          try
            let lfrom = " from " in
            let idx_from =
              let rec find_from i =
                if i >= String.length lsql then raise Not_found
                else if String.sub lsql i (String.length lfrom) = lfrom then i
                else find_from (i+1)
              in find_from 0
            in
            let start_tbl = idx_from + String.length lfrom in
            let rec skip_spaces j = if j < String.length lsql && lsql.[j] = ' ' then skip_spaces (j+1) else j in
            let tbl_start = skip_spaces start_tbl in
            let keywords = [" where "; " limit "; " group "; " order "; " settings "; " union "] in
            let next_kw_pos =
              List.filter_map (fun kw ->
                let rec find i =
                  if i >= String.length lsql then None
                  else if String.sub lsql i (String.length kw) = kw then Some i
                  else find (i+1)
                in find tbl_start
              ) keywords |> List.sort compare |> (function | x::_ -> x | [] -> String.length lsql)
            in
            let tbl_end = next_kw_pos in
            let before = String.sub sql 0 tbl_start in
            let tbl = String.sub sql tbl_start (tbl_end - tbl_start) |> String.trim in
            let after = String.sub sql tbl_end (String.length sql - tbl_end) in
            before ^ "table(" ^ tbl ^ ")" ^ after
          with _ -> sql
        )
      in
      let sql = wrap_table_if_needed original_sql in
      let contains s sub =
        let len_s = String.length s and len_sub = String.length sub in
        let rec loop i = if i + len_sub > len_s then false else if String.sub s i len_sub = sub then true else loop (i+1) in
        loop 0
      in
      let lsql = String.lowercase_ascii sql in
      let has_from = contains lsql " from " in
      let has_table_wrapper = contains lsql " from table(" in
      let has_limit = contains lsql " limit " in
      let is_unbounded = has_from && (not has_table_wrapper) && (not has_limit) in
      Printf.printf "SQL:  %s\n\n" sql;
      Srql_translator.Proton_client.Client.with_connection cfg (fun client ->

      let power10 p =
        let rec loop acc i = if i = 0 then acc else loop (Int64.mul acc 10L) (i-1) in
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
        match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> base ^ "Z" | _ -> base
      in
      let iso8601_of_datetime64 v precision tz_opt =
        let denom = power10 precision in
        let secs = Int64.div v denom in
        let frac = Int64.to_int (Int64.rem v denom) in
        let base = iso8601_of_datetime secs tz_opt in
        if precision > 0 then
          base ^ "." ^ pad_left (string_of_int frac) precision ^ (match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> "" | _ -> "")
        else base
      in
      let pretty_value typ v =
        let lt = String.lowercase_ascii (String.trim typ) in
        match (lt, v) with
        | ("bool", Proton.Column.UInt32 i) -> if Int32.to_int i = 0 then "false" else "true"
        | ("bool", Proton.Column.Int32 i) -> if Int32.to_int i = 0 then "false" else "true"
        | (lt, Proton.Column.DateTime (ts, tz)) when String.length lt >= 8 && String.sub lt 0 8 = "datetime" ->
            iso8601_of_datetime ts tz
        | (lt, Proton.Column.DateTime64 (v, p, tz)) when String.length lt >= 10 && String.sub lt 0 10 = "datetime64" ->
            iso8601_of_datetime64 v p tz
        | (_, other) -> Proton.Column.value_to_string other
      in

      if is_unbounded then (
        Printf.printf "Unbounded query detected; streaming via native protocol...\n";
        let printed_header = ref false in
        let* _cols =
          Proton.Client.query_iter_with_columns client sql ~f:(fun row columns ->
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
        Lwt.return_unit
      ) else (
        let* result = Srql_translator.Proton_client.Client.execute client sql in
        match result with
        | Proton.Client.NoRows ->
            Printf.printf "No rows returned.\n";
            Lwt.return_unit
        | Proton.Client.Rows (rows, columns) ->
           let power10 p =
             let rec loop acc i = if i = 0 then acc else loop (Int64.mul acc 10L) (i-1) in
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
             match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> base ^ "Z" | _ -> base
           in
           let iso8601_of_datetime64 v precision tz_opt =
             let denom = power10 precision in
             let secs = Int64.div v denom in
             let frac = Int64.to_int (Int64.rem v denom) in
             let base = iso8601_of_datetime secs tz_opt in
             if precision > 0 then
               base ^ "." ^ pad_left (string_of_int frac) precision ^ (match tz_opt with Some tz when String.lowercase_ascii tz = "utc" -> "" | _ -> "")
             else base
           in
           let pretty_value typ v =
             let lt = String.lowercase_ascii (String.trim typ) in
             match (lt, v) with
             | ("bool", Proton.Column.UInt32 i) -> if Int32.to_int i = 0 then "false" else "true"
             | ("bool", Proton.Column.Int32 i) -> if Int32.to_int i = 0 then "false" else "true"
             | (lt, Proton.Column.DateTime (ts, tz)) when String.length lt >= 8 && String.sub lt 0 8 = "datetime" ->
                 iso8601_of_datetime ts tz
             | (lt, Proton.Column.DateTime64 (v, p, tz)) when String.length lt >= 10 && String.sub lt 0 10 = "datetime64" ->
                 iso8601_of_datetime64 v p tz
             | (_, other) -> Proton.Column.value_to_string other
           in
           let row_count = List.length rows in
           let col_count = List.length columns in
           Printf.printf "Columns (%d): " col_count;
           List.iter (fun (name, typ) -> Printf.printf "%s:%s " name typ) columns;
           Printf.printf "\nRows (%d):\n" row_count;
           let max_show = min 10 row_count in
           let rec take n xs = match (n, xs) with 0, _ -> [] | _, [] -> [] | n, x::tl -> x :: take (n-1) tl in
           let to_show = take max_show rows in
           List.iteri (fun i row ->
             let values =
               List.map2 (fun (_, typ) v -> pretty_value typ v) columns row
             in
             Printf.printf "  %02d | %s\n" (i+1) (String.concat " | " values)
           ) to_show;
           if row_count > max_show then
             Printf.printf "... and %d more\n" (row_count - max_show);
            Lwt.return_unit)
    )
  in

  let run_native () =
    let try_no_compression =
      match compression with
      | None -> false
      | Some _ -> true
    in
    let cfg_no_compress = if try_no_compression then { config with compression = None } else config in
    let try_non_tls = config.use_tls in
    let cfg_non_tls = if try_non_tls then { config with use_tls = false; port = (getenv_int "PROTON_PORT_PLAIN" 8463) } else config in

    let rec try_steps = function
      | [] -> Lwt.fail_with "All native attempts failed"
      | (label, cfg) :: rest ->
          (if label <> "initial" then Printf.printf "%s...\n" label);
          Lwt.catch
            (fun () -> run_native_once cfg)
            (fun e ->
              Printf.printf "Attempt failed: %s\n" (Printexc.to_string e);
              try_steps rest)
    in
    let steps =
      let base = [ ("initial", config) ] in
      let base = if try_no_compression then base @ [ ("Retrying native without compression", cfg_no_compress) ] else base in
      let base = if try_non_tls then base @ [ (Printf.sprintf "Retrying native without TLS on port %d" cfg_non_tls.port, cfg_non_tls) ] else base in
      base
    in
    try_steps steps
  in

  let run () =
    Lwt.catch
      (fun () -> run_native ())
      (fun e ->
        Printf.printf "Native protocol failed: %s\n" (Printexc.to_string e);
        Lwt.fail e)
  in

  match Lwt.catch run (fun e -> Printf.printf "Error: %s\n" (Printexc.to_string e); Lwt.return_unit) |> Lwt_main.run with
  | () -> ()
