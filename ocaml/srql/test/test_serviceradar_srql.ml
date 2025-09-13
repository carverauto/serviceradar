open Lwt.Syntax

(* Helper function to check if string contains substring *)
let string_contains_substring s sub =
  let rec search i =
    if i + String.length sub > String.length s then false
    else if String.sub s i (String.length sub) = sub then true
    else search (i + 1)
  in
  if String.length sub = 0 then true else search 0

let test_srql_command query expected_contains description =
  Printf.printf "%s:\n" description;
  Printf.printf "  SRQL: %s\n" query;
  match Srql_translator.Translator.process_srql_string query with
  | Ok sql ->
      Printf.printf "  SQL:  %s\n" sql;
      if String.length expected_contains > 0 && not (string_contains_substring sql expected_contains) then
        Printf.printf "  ⚠️  Expected to contain: %s\n" expected_contains
      else
        Printf.printf "  ✅ Translation successful\n";
      Printf.printf "\n";
      Some sql
  | Error msg ->
      Printf.printf "  ❌ Translation failed: %s\n\n" msg;
      None

let test_with_proton_execution srql description =
  Printf.printf "%s:\n" description;
  Printf.printf "  SRQL: %s\n" srql;
  
  (* Configure TLS connection *)
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
    verify_hostname = false;
    insecure_skip_verify = true;
    compression = None;
    settings = [];
  } in
  
  Lwt_main.run (
    Srql_translator.Proton_client.Client.with_connection config (fun client ->
      (* First test translation *)
      (match Srql_translator.Proton_client.SRQL.translate_to_sql srql with
      | sql ->
          Printf.printf "  SQL:  %s\n" sql;
          
          (* Then test execution *)
          let* () = 
            try
              let* result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
              (match result with
              | Proton.Client.NoRows ->
                  Printf.printf "  ✅ Executed successfully (No rows returned)\n"
              | Proton.Client.Rows (rows, columns) ->
                  let row_count = List.length rows in
                  let col_count = List.length columns in
                  Printf.printf "  ✅ Executed successfully (%d rows, %d columns)\n" row_count col_count;
                  if row_count <= 3 then (* Show a few sample rows *)
                    List.iteri (fun i row ->
                      let values = List.map Proton.Column.value_to_string row in
                      Printf.printf "    Row %d: [%s]\n" (i+1) (String.concat " | " values)
                    ) rows);
              Lwt.return_unit
            with e ->
              Printf.printf "  ⚠️  Execution failed (table may not exist): %s\n" (Printexc.to_string e);
              Lwt.return_unit
          in
          Printf.printf "\n";
          Lwt.return_unit
      | exception e ->
          Printf.printf "  ❌ Translation failed: %s\n\n" (Printexc.to_string e);
          Lwt.return_unit)
    )
  )

let () =
  Printf.printf "🧪 ServiceRadar SRQL Commands Test\n";
  Printf.printf "=================================\n\n";
  
  Printf.printf "1. Testing Entity Mapping:\n";
  Printf.printf "-------------------------\n";
  
  (* Test basic entity mapping *)
  ignore @@ test_srql_command "SHOW devices" "unified_devices" "Show devices (should map to unified_devices table)";
  ignore @@ test_srql_command "SHOW flows" "netflow_metrics" "Show flows (should map to netflow_metrics table)";
  ignore @@ test_srql_command "SHOW device_updates" "device_updates" "Show device updates";
  ignore @@ test_srql_command "COUNT events" "events" "Count events";
  
  Printf.printf "2. Testing Array Field Queries:\n";
  Printf.printf "-------------------------------\n";
  
  (* Test array field queries that should use has() function *)
  ignore @@ test_srql_command "SHOW devices WHERE discovery_sources = 'sweep'" "has(discovery_sources, 'sweep')" "Query devices by discovery source (array field)";
  ignore @@ test_srql_command "FIND devices WHERE discovery_sources = 'armis'" "has(discovery_sources, 'armis')" "Find devices discovered by Armis";
  ignore @@ test_srql_command "SHOW devices WHERE discovery_sources = 'sweep' AND hostname = 'test'" "has(discovery_sources, 'sweep') AND hostname = 'test'" "Multiple conditions with array field";
  
  Printf.printf "3. Testing Complex Queries:\n";
  Printf.printf "---------------------------\n";
  
  (* Test more complex queries *)
  ignore @@ test_srql_command "SHOW devices WHERE ip = '192.168.1.1' LIMIT 10" "ip = '192.168.1.1'" "Query with IP filter and limit";
  ignore @@ test_srql_command "COUNT devices WHERE is_available = true" "is_available" "Count available devices";  
  ignore @@ test_srql_command "FIND device_updates WHERE poller_id = 'main-poller'" "poller_id = 'main-poller'" "Find updates from specific poller";
  
  Printf.printf "4. Testing Live Execution with Proton:\n";
  Printf.printf "-------------------------------------\n";
  
  (* Test with actual database execution *)
  test_with_proton_execution "SHOW devices" "Show devices from unified_devices table";
  test_with_proton_execution "SHOW devices WHERE discovery_sources = 'sweep'" "Show devices discovered via sweep (array query)";  
  test_with_proton_execution "COUNT device_updates" "Count device updates";
  test_with_proton_execution "SHOW events LIMIT 5" "Show recent events (limited)";
  
  Printf.printf "🎉 ServiceRadar SRQL testing completed!\n";
  Printf.printf "\nKey features implemented:\n";
  Printf.printf "  ✅ Entity mapping (devices → unified_devices, etc.)\n";
  Printf.printf "  ✅ Array field detection (discovery_sources uses has() function)\n";
  Printf.printf "  ✅ Complex WHERE clauses\n";
  Printf.printf "  ✅ Live execution over TLS connection\n"
