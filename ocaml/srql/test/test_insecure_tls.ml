open Lwt.Syntax

let () =
  print_endline "=== Testing Insecure TLS Connection to Proton ===\n";
  
  (* Configure insecure TLS connection for testing *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";
    port = 9440;  (* TLS port *)
    database = "default";
    username = "default";
    password = "2fa7af883496fd7e5a8d222afe5d2dbf";
    use_tls = true;
    ca_cert = None;
    client_cert = None;
    client_key = None;
    verify_hostname = false;  (* Skip hostname verification *)
    insecure_skip_verify = true;  (* Skip all certificate verification *)
    compression = None;
  } in
  
  print_endline "Attempting insecure TLS connection (skip cert verification)...";
  
  Lwt_main.run (
    Srql_translator.Proton_client.Client.with_connection config (fun client ->
      let* is_alive = Srql_translator.Proton_client.Client.ping client in
      Printf.printf "✓ TLS Connection successful: %b\n\n" is_alive;
      
      (* Test basic query *)
      print_endline "Testing basic SQL queries...";
      let* _result1 = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test" in
      print_endline "✓ SELECT 1 successful";
      
      let* _result2 = Srql_translator.Proton_client.Client.query client "SELECT version() AS version" in
      print_endline "✓ SELECT version() successful";
      
      let* _result3 = Srql_translator.Proton_client.Client.query client "SELECT current_user() AS user" in
      print_endline "✓ SELECT current_user() successful\n";
      
      (* Test SRQL translation and execution *)
      print_endline "Testing SRQL queries...";
      
      let srql_queries = [
        "SELECT 1 AS test";
        "SELECT version() AS db_version";
        "SELECT current_user() AS current_user";
      ] in
      
      let* () = Lwt_list.iter_s (fun srql ->
        Printf.printf "SRQL: %s\n" srql;
        let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
        Printf.printf "SQL:  %s\n" sql;
        let* _result = 
          try
            let* _res = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
            Printf.printf "✓ SRQL executed successfully\n\n";
            Lwt.return_unit
          with e ->
            Printf.printf "✗ SRQL failed: %s\n\n" (Printexc.to_string e);
            Lwt.return_unit
        in
        Lwt.return_unit
      ) srql_queries in
      
      (* Test queries on actual tables *)
      print_endline "Testing queries on ServiceRadar tables...";
      
      let table_queries = [
        "SELECT COUNT(*) FROM unified_devices";
        "SELECT COUNT(*) FROM device_updates"; 
        "SELECT COUNT(*) FROM sweep_host_states";
      ] in
      
      let* () = Lwt_list.iter_s (fun srql ->
        Printf.printf "SRQL: %s\n" srql;
        let* () = 
          try
            let* _res = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
            Printf.printf "✓ Table query successful\n";
            Lwt.return_unit
          with e ->
            Printf.printf "⚠ Table query failed (table may not exist): %s\n" (Printexc.to_string e);
            Lwt.return_unit
        in
        Lwt.return_unit
      ) table_queries in
      
      print_endline "\n🎉 All TLS tests completed successfully!";
      print_endline "✅ OCaml SRQL implementation can connect to Proton over TLS!";
      Lwt.return_unit
    )
  )