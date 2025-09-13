open Lwt.Syntax

let () =
  print_endline "=== Simple Proton Connection Test ===\n";
  
  let test_connection port use_tls desc =
    Printf.printf "Testing %s on port %d...\n" desc port;
  let config = Srql_translator.Proton_client.Config.{
      host = "localhost";
      port = port;
      database = "default";
      username = "default";
      password = "2fa7af883496fd7e5a8d222afe5d2dbf";
      use_tls = use_tls;
      ca_cert = None;
      client_cert = None;
      client_key = None;
      verify_hostname = false;
      insecure_skip_verify = true;  (* For dev/self-signed certs *)
    compression = None;
    settings = [];
  } in
    
    Srql_translator.Proton_client.Client.with_connection config (fun client ->
      let* is_alive = Srql_translator.Proton_client.Client.ping client in
      Printf.printf "✓ Connection successful: %b\n" is_alive;
      
      (* Test a simple query *)
      let* result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test, version()" in
      (match result with
      | Proton.Client.NoRows -> print_endline "No rows returned"
      | Proton.Client.Rows (data, columns) ->
          Printf.printf "Got %d rows with columns: " (List.length data);
          List.iter (fun (name, typ) -> Printf.printf "%s:%s " name typ) columns;
          print_endline "");
      
      (* Test SRQL translation and execution *)
      print_endline "\nTesting SRQL queries:";
      let srql_queries = [
        "SELECT 1";
        "SELECT now() AS current_time";
        "SELECT version() AS db_version";
      ] in
      
      let* () = Lwt_list.iter_s (fun srql ->
        Printf.printf "  SRQL: %s\n" srql;
        let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
        Printf.printf "  SQL:  %s\n" sql;
        let* _result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
        print_endline "  ✓ Executed successfully";
        Lwt.return_unit
      ) srql_queries in
      
      print_endline "";
      Lwt.return_unit
    )
  in
  
  Lwt_main.run (
    (* Try different connection options *)
    let connections = [
      (8463, false, "Non-TLS on 8463");
      (8123, false, "HTTP port 8123");
      (9440, true, "TLS on 9440");
    ] in
    
    Lwt_list.iter_s (fun (port, use_tls, desc) ->
      try
        test_connection port use_tls desc
      with e ->
        Printf.printf "✗ Failed: %s\n\n" (Printexc.to_string e);
        Lwt.return_unit
    ) connections
  );
  
  print_endline "=== Test completed ==="
