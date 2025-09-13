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
  (* Read SRQL from CLI or use default *)
  let srql =
    if Array.length Sys.argv > 1 then
      String.concat " " (Array.to_list (Array.sub Sys.argv 1 (Array.length Sys.argv - 1)))
    else
      "SHOW devices LIMIT 10"
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
  } in

  Printf.printf "Connecting: host=%s port=%d tls=%b db=%s user=%s compression=%s\n\n"
    host port use_tls database username (match compression with None -> "none" | Some _ -> "lz4");

  let http_mode = getenv_bool "PROTON_HTTP" false in

  let run_native () =
    Srql_translator.Proton_client.Client.with_connection config (fun client ->
      let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
      Printf.printf "SQL:  %s\n\n" sql;

      let* result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
      (match result with
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

  let url_encode s =
    let buf = Buffer.create (String.length s * 2) in
    String.iter (fun c ->
      let code = Char.code c in
      let is_unreserved =
        (code >= 48 && code <= 57) || (* 0-9 *)
        (code >= 65 && code <= 90) || (* A-Z *)
        (code >= 97 && code <= 122) || (* a-z *)
        c = '-' || c = '_' || c = '.' || c = '~'
      in
      if is_unreserved then Buffer.add_char buf c
      else if c = ' ' then Buffer.add_string buf "%20"
      else Buffer.add_string buf (Printf.sprintf "%%%02X" code)
    ) s;
    Buffer.contents buf
  in

  let run_http () =
    let http_port = getenv_int "PROTON_HTTP_PORT" 8123 in
    let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
    Printf.printf "SQL:  %s\n\n" sql;

    let query = url_encode sql in
    let user_q = url_encode username in
    let pass_q = url_encode password in
    let format_q = url_encode "TabSeparatedWithNamesAndTypes" in
    let path = Printf.sprintf 
      "/?user=%s&password=%s&default_format=%s&output_format_write_statistics=0&query=%s"
      user_q pass_q format_q query in

    let addr = Unix.inet_addr_of_string "127.0.0.1" in
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    let () = Unix.connect sock (Unix.ADDR_INET (addr, http_port)) in
    let req = Printf.sprintf "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" path host in
    ignore (Unix.write_substring sock req 0 (String.length req));

    let buf = Bytes.create 4096 in
    let response = Buffer.create 16384 in
    let rec read_all () =
      match Unix.read sock buf 0 (Bytes.length buf) with
      | 0 -> ()
      | n -> Buffer.add_subbytes response buf 0 n; read_all ()
    in
    read_all ();
    Unix.close sock;

    let resp = Buffer.contents response in
    let header_end = try String.index_from resp 0 '\n' with Not_found -> 0 in
    let status_line = if header_end > 0 then String.sub resp 0 (header_end - 1) else "" in
    Printf.printf "HTTP: %s\n" status_line;
    let body =
      match String.index_opt resp '\n' with
      | None -> resp
      | Some _ ->
          (* crude split on first blank line between headers and body *)
          (match String.split_on_char '\n' resp with
           | lines ->
               let rec drop_headers = function
                 | [] -> []
                 | l :: tl -> if String.trim l = "" then tl else drop_headers tl
               in
               String.concat "\n" (drop_headers lines))
    in
    (* Print first ~10 lines of the body *)
    let lines = String.split_on_char '\n' body in
    let rec print_first n = function
      | _ when n <= 0 -> ()
      | [] -> ()
      | l :: tl -> Printf.printf "%s\n" l; print_first (n-1) tl
    in
    print_endline "Rows (first 10):";
    print_first 10 lines;
    Lwt.return_unit
  in

  let run () =
    if http_mode then run_http ()
    else Lwt.catch
      (fun () -> run_native ())
      (fun e ->
        Printf.printf "Native protocol failed: %s\nFalling back to HTTP on port %d...\n\n"
          (Printexc.to_string e) (getenv_int "PROTON_HTTP_PORT" 8123);
        run_http ())
  in

  match Lwt.catch run (fun e -> Printf.printf "Error: %s\n" (Printexc.to_string e); Lwt.return_unit) |> Lwt_main.run with
  | () -> ()
