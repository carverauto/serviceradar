open Lwt.Syntax

module Config = struct
  type t = {
    host : string;
    port : int;
    database : string;
    username : string;
    password : string;
    use_tls : bool;
    ca_cert : string option;
    client_cert : string option;
    client_key : string option;
    verify_hostname : bool;
    insecure_skip_verify : bool;
    compression : Proton.Compress.method_t option;
    settings : (string * string) list;
  }

  let default = {
    host = "localhost";
    port = 8463;
    database = "default";
    username = "default";
    password = "";
    use_tls = false;
    ca_cert = None;
    client_cert = None;
    client_key = None;
    verify_hostname = true;
    insecure_skip_verify = false;
    compression = Some Proton.Compress.LZ4;
    settings = [];
  }

  let with_tls ?(ca_cert=None) ?(client_cert=None) ?(client_key=None) 
              ?(verify_hostname=true) ?(insecure_skip_verify=false) config =
    { config with 
      use_tls = true;
      ca_cert;
      client_cert;
      client_key;
      verify_hostname;
      insecure_skip_verify;
      settings = config.settings;
    }

  let local_docker_tls = 
    { default with
      host = "serviceradar-proton";
      port = 9440;  (* TLS port from docker-compose.yml *)
      use_tls = true;
      ca_cert = Some "/etc/serviceradar/certs/ca.crt";
      client_cert = Some "/etc/serviceradar/certs/client.crt";
      client_key = Some "/etc/serviceradar/certs/client.key";
      verify_hostname = false;  (* For local testing *)
      insecure_skip_verify = false;
    }
    
  let local_docker_no_tls =
    { default with
      host = "serviceradar-proton";
      port = 8463;  (* Non-TLS port *)
      use_tls = false;
    }
end

module Client = struct
  type t = Proton.Client.t

  let connect config =
    let tls_config = 
      if config.Config.use_tls then
        Some {
          Proton.Connection.enable_tls = true;
          ca_cert_file = config.ca_cert;
          client_cert_file = config.client_cert;
          client_key_file = config.client_key;
          verify_hostname = config.verify_hostname;
          insecure_skip_verify = config.insecure_skip_verify;
        }
      else None
    in
    
    let client =
      match config.compression with
      | None ->
          Proton.Client.create
            ~host:config.Config.host
            ~port:config.port
            ~database:config.database
            ~user:config.username
            ~password:config.password
            ~settings:config.settings
            ?tls_config
            ~compression:Proton.Compress.None
            ()
      | Some cmpr ->
          Proton.Client.create
            ~host:config.Config.host
            ~port:config.port
            ~database:config.database
            ~user:config.username
            ~password:config.password
            ~settings:config.settings
            ?tls_config
            ~compression:cmpr
            ()
    in
    
    (* Client is created and ready - no separate connect needed *)
    Lwt.return client

  let execute client query =
    Proton.Client.execute client query

  let query client query =
    Proton.Client.execute client query

  let close client =
    Proton.Client.disconnect client

  let ping client =
    (* Execute a simple query to check connection *)
    let* result = Proton.Client.execute client "SELECT 1" in
    match result with
    | Proton.Client.NoRows -> Lwt.return false
    | Proton.Client.Rows _ -> Lwt.return true

  let with_connection config f =
    let* client = connect config in
    Lwt.finalize
      (fun () -> f client)
      (fun () -> close client)
end

(* SRQL-specific query execution *)
module SRQL = struct
  let translate_and_execute client srql_query =
    (* Parse SRQL query *)
    let lexbuf = Lexing.from_string srql_query in
    let ast = Parser.query Lexer.token lexbuf in
    
    (* Translate to SQL using existing translator *)
    let sql = Translator.translate_query ast in
    
    (* Execute the SQL query *)
    Client.execute client sql

  let translate_to_sql srql_query =
    let lexbuf = Lexing.from_string srql_query in
    let ast = Parser.query Lexer.token lexbuf in
    let base_sql = Translator.translate_query ast in
    (* Proton requires FROM table(<name>) for snapshot semantics in many cases. 
       Wrap FROM target with table(...) if not already present. *)
    let lsql = String.lowercase_ascii base_sql in
    let contains s sub =
      let len_s = String.length s and len_sub = String.length sub in
      let rec loop i = if i + len_sub > len_s then false else if String.sub s i len_sub = sub then true else loop (i+1) in
      loop 0
    in
    let has_from = contains lsql " from " in
    let has_table_wrapper = contains lsql " from table(" in
    if (not has_from) || has_table_wrapper then base_sql
    else (
      (* Find the table identifier after FROM and wrap it with table(...) until next keyword *)
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
        let before = String.sub base_sql 0 tbl_start in
        let tbl = String.sub base_sql tbl_start (tbl_end - tbl_start) |> String.trim in
        let after = String.sub base_sql tbl_end (String.length base_sql - tbl_end) in
        before ^ "table(" ^ tbl ^ ")" ^ after
      with _ -> base_sql
    )
end
