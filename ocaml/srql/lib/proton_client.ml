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
    
    let client = Proton.Client.create 
      ~host:config.Config.host
      ~port:config.port
      ~database:config.database
      ~user:config.username
      ~password:config.password
      ?tls_config
      ?compression:config.compression
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
    Translator.translate_query ast
end