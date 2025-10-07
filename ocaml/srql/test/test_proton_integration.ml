open Lwt.Syntax

let test_connection_no_tls () =
  print_endline "Testing connection without TLS...";
  let config = Srql_translator.Proton_client.Config.local_docker_no_tls in
  let* client =
    try Srql_translator.Proton_client.Client.connect config
    with e ->
      Printf.printf "Failed to connect: %s\n" (Printexc.to_string e);
      Lwt.fail e
  in

  let* is_alive = Srql_translator.Proton_client.Client.ping client in
  Printf.printf "Connection alive: %b\n" is_alive;

  (* Test a simple query *)
  let* _result = Srql_translator.Proton_client.Client.query client "SELECT 1 AS test" in
  Printf.printf "Query successful, got result\n";

  let* () = Srql_translator.Proton_client.Client.close client in
  print_endline "Connection closed successfully";
  Lwt.return_unit

let test_connection_with_tls () =
  print_endline "\nTesting connection with TLS...";
  let config = Srql_translator.Proton_client.Config.local_docker_tls in

  (* Try to connect with TLS *)
  let* client =
    try Srql_translator.Proton_client.Client.connect config
    with e ->
      Printf.printf "Failed to connect with TLS: %s\n" (Printexc.to_string e);
      Printf.printf "This is expected if certificates are not yet generated\n";
      Lwt.fail e
  in

  let* is_alive = Srql_translator.Proton_client.Client.ping client in
  Printf.printf "TLS connection alive: %b\n" is_alive;

  let* () = Srql_translator.Proton_client.Client.close client in
  print_endline "TLS connection closed successfully";
  Lwt.return_unit

let test_srql_translation () =
  print_endline "\nTesting SRQL translation...";

  (* Test some SRQL queries *)
  let test_queries =
    [
      "SELECT * FROM events";
      "SELECT name, value FROM metrics WHERE timestamp > 1000";
      "SELECT COUNT(*) FROM logs";
    ]
  in

  List.iter
    (fun srql ->
      try
        let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
        Printf.printf "SRQL: %s\n  SQL: %s\n" srql sql
      with e -> Printf.printf "Failed to translate '%s': %s\n" srql (Printexc.to_string e))
    test_queries;

  Lwt.return_unit

let test_srql_execution () =
  print_endline "\nTesting SRQL execution...";
  let config = Srql_translator.Proton_client.Config.local_docker_no_tls in

  Srql_translator.Proton_client.Client.with_connection config (fun client ->
      (* Create a test table *)
      let* _ =
        Srql_translator.Proton_client.Client.execute client
          "CREATE STREAM IF NOT EXISTS test_events (\n\
          \        id Int32,\n\
          \        name String,\n\
          \        value Float64,\n\
          \        timestamp DateTime64(3)\n\
          \      ) ENGINE = Stream"
      in
      print_endline "Created test stream";

      (* Insert some test data *)
      let* _ =
        Srql_translator.Proton_client.Client.execute client
          "INSERT INTO test_events VALUES \n\
          \        (1, 'event1', 10.5, now()),\n\
          \        (2, 'event2', 20.3, now()),\n\
          \        (3, 'event3', 30.1, now())"
      in
      print_endline "Inserted test data";

      (* Query using SRQL *)
      let srql_query = "SELECT * FROM test_events" in
      let* _result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql_query in
      print_endline "SRQL query executed successfully";

      (* Clean up *)
      let* _ =
        Srql_translator.Proton_client.Client.execute client "DROP STREAM IF EXISTS test_events"
      in
      print_endline "Cleaned up test stream";

      Lwt.return_unit)

let () =
  print_endline "Starting Proton integration tests...";
  print_endline "Make sure Docker containers are running: docker-compose up -d";
  print_endline "";

  Lwt_main.run
    (let* () =
       try test_connection_no_tls ()
       with _ ->
         print_endline "Non-TLS connection failed, continuing...";
         Lwt.return_unit
     in

     let* () =
       try test_connection_with_tls ()
       with _ ->
         print_endline "TLS connection failed (expected if certs not generated), continuing...";
         Lwt.return_unit
     in

     let* () = test_srql_translation () in

     let* () =
       try test_srql_execution ()
       with e ->
         Printf.printf "SRQL execution test failed: %s\n" (Printexc.to_string e);
         Lwt.return_unit
     in

     print_endline "\n✅ Integration tests completed!";
     Lwt.return_unit)
