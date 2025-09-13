open Lwt.Syntax

let test_tls_connection () =
  print_endline "=== Testing TLS Connection to Proton on port 9440 ===\n";
  
  (* Get absolute paths to certificates *)
  let cwd = Sys.getcwd () in
  let ca_cert_path = Printf.sprintf "%s/certs/root.pem" cwd in
  let client_cert_path = Printf.sprintf "%s/certs/proton.pem" cwd in
  let client_key_path = Printf.sprintf "%s/certs/proton-key.pem" cwd in
  
  Printf.printf "Using certificates:\n";
  Printf.printf "  CA cert: %s\n" ca_cert_path;
  Printf.printf "  Client cert: %s\n" client_cert_path;
  Printf.printf "  Client key: %s\n\n" client_key_path;
  
  (* Configure TLS connection *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";  (* We'll connect to localhost but verify against proton.serviceradar *)
    port = 9440;  (* TLS port *)
    database = "default";
    username = "default";
    password = "2fa7af883496fd7e5a8d222afe5d2dbf";
    use_tls = true;
    ca_cert = Some ca_cert_path;
    client_cert = Some client_cert_path;
    client_key = Some client_key_path;
    verify_hostname = false;  (* Since we're connecting to localhost but cert is for proton.serviceradar *)
    insecure_skip_verify = false;  (* We want to verify the cert with our CA *)
    compression = None;
    settings = [];
  } in
  
  print_endline "Attempting TLS connection with mTLS certificates...";
  
  Srql_translator.Proton_client.Client.with_connection config (fun client ->
    let* is_alive = Srql_translator.Proton_client.Client.ping client in
    Printf.printf "✓ TLS Connection successful: %b\n\n" is_alive;
    
    (* Test basic queries *)
    print_endline "Testing basic queries over TLS...";
    
    let queries = [
      ("SELECT 1 AS test", "Simple test query");
      ("SELECT version() AS version", "Version query");
      ("SELECT current_user() AS user", "Current user query");
      ("SHOW DATABASES", "Show databases");
    ] in
    
    let* () = Lwt_list.iter_s (fun (query, desc) ->
      Printf.printf "  %s: %s\n" desc query;
      let* result = 
        try
          let* _res = Srql_translator.Proton_client.Client.query client query in
          Printf.printf "  ✓ Success\n";
          Lwt.return_unit
        with e ->
          Printf.printf "  ✗ Failed: %s\n" (Printexc.to_string e);
          Lwt.return_unit
      in
      Lwt.return result
    ) queries in
    
    (* Test SRQL translation and execution *)
    print_endline "\nTesting SRQL queries over TLS...";
    
    let srql_queries = [
      "SELECT 1";
      "SELECT COUNT(*) FROM unified_devices";
      "SELECT version()";
    ] in
    
    let* () = Lwt_list.iter_s (fun srql ->
      Printf.printf "  SRQL: %s\n" srql;
      let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
      Printf.printf "  SQL:  %s\n" sql;
      let* result = 
        try
          let* _res = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
          Printf.printf "  ✓ SRQL executed successfully\n";
          Lwt.return_unit
        with e ->
          Printf.printf "  ✗ SRQL failed: %s\n" (Printexc.to_string e);
          Lwt.return_unit
      in
      Lwt.return result
    ) srql_queries in
    
    print_endline "\n✅ TLS connection test completed!";
    Lwt.return_unit
  )

let test_insecure_tls () =
  print_endline "=== Testing Insecure TLS Connection (for comparison) ===\n";
  
  (* Configure insecure TLS connection for development *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";
    port = 9440;
    database = "default";
    username = "default";
    password = "2fa7af883496fd7e5a8d222afe5d2dbf";
    use_tls = true;
    ca_cert = None;
    client_cert = None;
    client_key = None;
    verify_hostname = false;
    insecure_skip_verify = true;  (* Skip all certificate verification *)
    compression = None;
    settings = [];
  } in
  
  print_endline "Attempting insecure TLS connection...";
  
  Srql_translator.Proton_client.Client.with_connection config (fun client ->
    let* is_alive = Srql_translator.Proton_client.Client.ping client in
    Printf.printf "✓ Insecure TLS Connection successful: %b\n" is_alive;
    
    let* _result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test" in
    print_endline "✓ Query successful over insecure TLS\n";
    
    Lwt.return_unit
  )

let () =
  Lwt_main.run (
    let* () = 
      try
        test_tls_connection ()
      with e ->
        Printf.printf "Secure TLS connection failed: %s\n\n" (Printexc.to_string e);
        Printf.printf "Trying insecure TLS as fallback...\n\n";
        test_insecure_tls ()
    in
    
    print_endline "=== TLS tests completed ===";
    Lwt.return_unit
  )
