open Lwt.Syntax

let test_translation query expected =
  Printf.printf "Testing SRQL: %s\n" query;
  match Srql_translator.Translator.process_srql_string query with
  | Ok sql ->
      Printf.printf "  ✓ Translated to: %s\n" sql;
      if String.trim sql = String.trim expected then
        Printf.printf "  ✅ Translation matches expected result\n\n"
      else
        Printf.printf "  ⚠️  Expected: %s\n  ⚠️  Got: %s\n\n" expected sql
  | Error msg ->
      Printf.printf "  ❌ Translation failed: %s\n\n" msg

let test_with_proton_connection () =
  print_endline "🧪 Testing SRQL Translation with Proton Connection\n";
  print_endline "=================================================\n";
  
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
      print_endline "📊 Testing SRQL translation and execution:\n";
      
      let srql_tests = [
        ("SELECT 1", "Simple SELECT query");
        ("SELECT version()", "Function call query");
        ("SHOW unified_devices LIMIT 1", "SHOW query with actual table");
        ("COUNT unified_devices", "COUNT query with actual table");
        ("SELECT device_id FROM unified_devices LIMIT 1", "SELECT with field and table");
      ] in
      
      let* () = Lwt_list.iter_s (fun (srql, description) ->
        Printf.printf "%s: %s\n" description srql;
        
        (* First test the translation *)
        (match Srql_translator.Proton_client.SRQL.translate_to_sql srql with
        | sql ->
            Printf.printf "  📝 Translated to SQL: %s\n" sql;
            
            (* Then test execution with proper async exception handling *)
            let* () =
              Lwt.catch
                (fun () ->
                  let* _result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
                  Printf.printf "  ✅ Executed successfully\n";
                  Lwt.return_unit)
                (fun e ->
                  Printf.printf "  ⚠️  Execution failed: %s\n" (Printexc.to_string e);
                  Lwt.return_unit)
            in
            Printf.printf "\n";
            Lwt.return_unit
        | exception e ->
            Printf.printf "  ❌ Translation failed: %s\n\n" (Printexc.to_string e);
            Lwt.return_unit)
      ) srql_tests in
      
      Lwt.return_unit
    )
  )

let () =
  print_endline "🔧 SRQL Translation Tests\n";
  print_endline "========================\n";
  
  print_endline "1. Testing basic SRQL parsing and translation:";
  print_endline "----------------------------------------------\n";
  
  (* Test basic SELECT queries *)
  test_translation "SELECT 1" "SELECT 1";
  test_translation "SELECT version()" "SELECT version()";
  
  (* Test SHOW/FIND/COUNT queries with correct ServiceRadar table mappings *)
  test_translation "SHOW devices" "SELECT * FROM unified_devices";
  test_translation "COUNT devices" "SELECT count() FROM unified_devices";
  test_translation "FIND devices WHERE id = 1" "SELECT * FROM unified_devices WHERE id = 1";
  
  print_endline "2. Testing with live Proton connection:";
  print_endline "--------------------------------------\n";
  
  test_with_proton_connection ()
