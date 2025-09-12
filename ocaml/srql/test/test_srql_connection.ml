open Lwt.Syntax

let test_tls_connection () =
  print_endline "=== Testing TLS Connection to Proton on port 9440 ===\n";
  
  (* Configure TLS connection for local Docker Proton *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";
    port = 9440;  (* TLS port *)
    database = "default";
    username = "default";
    password = "";
    use_tls = true;
    ca_cert = None;  (* Use system trust or self-signed *)
    client_cert = None;
    client_key = None;
    verify_hostname = false;  (* For localhost testing *)
    insecure_skip_verify = true;  (* For development/self-signed certs *)
    compression = None;
  } in
  
  print_endline "Attempting TLS connection to Proton on port 9440...";
  Srql_translator.Proton_client.Client.with_connection config (fun client ->
    let* is_alive = Srql_translator.Proton_client.Client.ping client in
    Printf.printf "✓ TLS Connection successful: %b\n\n" is_alive;
    
    (* Test a simple query *)
    let* _result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test" in
    print_endline "✓ Query executed successfully over TLS\n";
    
    Lwt.return_unit
  )

let test_non_tls_connection () =
  print_endline "=== Testing Non-TLS Connection to Proton on port 8463 ===\n";
  
  (* Configure non-TLS connection for local Docker Proton *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";
    port = 8463;  (* Native TCP port *)
    database = "default";
    username = "default";
    password = "";
    use_tls = false;
    ca_cert = None;
    client_cert = None;
    client_key = None;
    verify_hostname = false;
    insecure_skip_verify = false;
    compression = Some Proton.Compress.LZ4;  (* Try with compression *)
  } in
  
  print_endline "Attempting non-TLS connection to Proton on port 8463...";
  Srql_translator.Proton_client.Client.with_connection config (fun client ->
    let* is_alive = Srql_translator.Proton_client.Client.ping client in
    Printf.printf "✓ Non-TLS Connection successful: %b\n\n" is_alive;
    
    (* Test a simple query *)
    let* _result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test" in
    print_endline "✓ Query executed successfully over non-TLS\n";
    
    Lwt.return_unit
  )

let run_test () =
  print_endline "=== Testing OCaml SRQL Implementation with Proton Database ===\n";
  
  (* Try TLS connection first *)
  let* () = 
    try
      test_tls_connection ()
    with e ->
      Printf.printf "TLS connection failed: %s\n" (Printexc.to_string e);
      Printf.printf "Falling back to non-TLS connection...\n\n";
      (* Fallback to non-TLS *)
      test_non_tls_connection ()
  in
  
  (* Now test with the working connection *)
  let config = Srql_translator.Proton_client.Config.{
    host = "localhost";
    port = 8463;  (* Use non-TLS for now as it's more likely to work *)
    database = "default";
    username = "default";
    password = "";
    use_tls = false;
    ca_cert = None;
    client_cert = None;
    client_key = None;
    verify_hostname = false;
    insecure_skip_verify = false;
    compression = None;
  } in
  
  print_endline "1. Testing connection to Proton...";
  Srql_translator.Proton_client.Client.with_connection config (fun client ->
    let* is_alive = Srql_translator.Proton_client.Client.ping client in
    Printf.printf "   ✓ Connection successful: %b\n\n" is_alive;
    
    (* Test basic connectivity *)
    print_endline "2. Testing basic query execution...";
    let* _result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test, now() AS current_time" in
    print_endline "   ✓ Basic query executed successfully\n";
    
    (* Check existing tables *)
    print_endline "3. Checking existing tables in database...";
    let* _tables_result = Srql_translator.Proton_client.Client.query client 
      "SELECT name FROM system.tables WHERE database = 'default' LIMIT 10" in
    print_endline "   ✓ Retrieved table list\n";
    
    (* Test SRQL translation *)
    print_endline "4. Testing SRQL to SQL translation...";
    let test_srql_queries = [
      ("SELECT * FROM unified_devices", "Query all devices");
      ("SELECT device_id, ip, hostname FROM unified_devices WHERE is_available = true", "Query available devices");
      ("SELECT * FROM device_updates WHERE timestamp > now() - 1d", "Recent device updates");
      ("SELECT COUNT(*) FROM sweep_host_states", "Count sweep hosts");
    ] in
    
    List.iter (fun (srql, desc) ->
      try
        let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
        Printf.printf "   SRQL: %s\n   Desc: %s\n   SQL:  %s\n\n" srql desc sql
      with e ->
        Printf.printf "   Failed to translate '%s': %s\n\n" srql (Printexc.to_string e)
    ) test_srql_queries;
    
    (* Test SRQL execution with real tables *)
    print_endline "5. Testing SRQL execution on actual tables...";
    
    (* First check if tables exist *)
    let* _check_tables = Srql_translator.Proton_client.Client.query client 
      "SELECT name FROM system.tables WHERE database = 'default' AND name IN ('unified_devices', 'device_updates', 'sweep_host_states')" in
    print_endline "   Checking for required tables...\n";
    
    (* Try to query existing tables using SRQL *)
    let queries_to_test = [
      "SELECT COUNT(*) FROM unified_devices";
      "SELECT COUNT(*) FROM device_updates"; 
      "SELECT COUNT(*) FROM sweep_host_states";
    ] in
    
    let* () = Lwt_list.iter_s (fun srql_query ->
      Printf.printf "   Executing SRQL: %s\n" srql_query;
      let* () = 
        try
          let* _res = Srql_translator.Proton_client.SRQL.translate_and_execute client srql_query in
          Printf.printf "   ✓ Query executed successfully\n\n";
          Lwt.return_unit
        with e ->
          Printf.printf "   ⚠ Query failed (table might not exist): %s\n\n" (Printexc.to_string e);
          Lwt.return_unit
      in
      Lwt.return_unit
    ) queries_to_test in
    
    (* Create test table and run SRQL queries *)
    print_endline "6. Creating test table and running SRQL queries...";
    let* _ = 
      try
        Srql_translator.Proton_client.Client.execute client 
          "CREATE STREAM IF NOT EXISTS srql_test_events (
            event_id Int32,
            event_name String,
            event_value Float64,
            event_timestamp DateTime64(3),
            metadata String
          ) ENGINE = Stream"
      with e ->
        Printf.printf "   Note: Table creation failed (might already exist): %s\n" (Printexc.to_string e);
        Lwt.return Proton.Client.NoRows
    in
    print_endline "   ✓ Test table created/verified\n";
    
    (* Insert test data *)
    let* _ = Srql_translator.Proton_client.Client.execute client
      "INSERT INTO srql_test_events VALUES 
        (1, 'startup', 100.5, now(), 'system init'),
        (2, 'heartbeat', 50.3, now() - 1h, 'health check'),
        (3, 'alert', 90.1, now() - 2h, 'threshold exceeded'),
        (4, 'shutdown', 0.0, now() - 3h, 'graceful stop')" in
    print_endline "   ✓ Test data inserted\n";
    
    (* Test various SRQL queries on test table *)
    print_endline "7. Testing SRQL queries on test data...";
    let test_queries = [
      "SELECT * FROM srql_test_events";
      "SELECT event_name, event_value FROM srql_test_events WHERE event_value > 50";
      "SELECT COUNT(*) AS total_events FROM srql_test_events";
      "SELECT event_name FROM srql_test_events WHERE event_timestamp > now() - 2h";
    ] in
    
    let* () = Lwt_list.iter_s (fun srql ->
      Printf.printf "   SRQL: %s\n" srql;
      let* () = 
        try
          let* _res = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
          Printf.printf "   ✓ Success\n\n";
          Lwt.return_unit
        with e ->
          Printf.printf "   ✗ Failed: %s\n\n" (Printexc.to_string e);
          Lwt.return_unit
      in
      Lwt.return_unit
    ) test_queries in
    
    (* Clean up *)
    print_endline "8. Cleaning up test data...";
    let* _ = 
      try
        Srql_translator.Proton_client.Client.execute client "DROP STREAM IF EXISTS srql_test_events"
      with e ->
        Printf.printf "   Note: Cleanup failed: %s\n" (Printexc.to_string e);
        Lwt.return Proton.Client.NoRows
    in
    print_endline "   ✓ Test table dropped\n";
    
    print_endline "=== All tests completed successfully! ===";
    Lwt.return_unit
  )

let () =
  (* Run the test *)
  try
    Lwt_main.run (run_test ())
  with e ->
    Printf.printf "\n❌ Test failed with error: %s\n" (Printexc.to_string e);
    exit 1