open Lwt.Syntax

let test_srql_with_simple_tables () =
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
  } in
  
  Lwt_main.run (
    Srql_translator.Proton_client.Client.with_connection config (fun client ->
      let srql_queries = [
        (* Basic SELECT queries that should work *)
        "SELECT 1";
        "SELECT version()";
        (* Try queries on simpler tables *)
        "SELECT COUNT(*) FROM pollers";
        "SELECT poller_id FROM pollers LIMIT 2";
        "SELECT COUNT(*) FROM events";
        "SELECT id, type FROM events LIMIT 2";
      ] in
      
      Lwt_list.iter_s (fun srql ->
        Printf.printf "Testing SRQL: %s\n" srql;
        
        (* First test translation *)
        let* () = 
          try
            let sql = Srql_translator.Proton_client.SRQL.translate_to_sql srql in
            Printf.printf "  📝 Translated to SQL: %s\n" sql;
            
            (* Then test execution *)
            let* () = 
              try
                let* result = Srql_translator.Proton_client.SRQL.translate_and_execute client srql in
                (match result with
                | Proton.Client.NoRows ->
                    Printf.printf "  ✅ Executed successfully (No rows)\n";
                    Lwt.return_unit
                | Proton.Client.Rows (rows, columns) ->
                    let row_count = List.length rows in
                    let col_count = List.length columns in
                    Printf.printf "  ✅ Executed successfully (%d rows, %d columns)\n" row_count col_count;
                    
                    (* Show sample data for small result sets *)
                    if row_count <= 3 && row_count > 0 then (
                      List.iteri (fun i row ->
                        let values = List.map Proton.Column.value_to_string row in
                        Printf.printf "    Row %d: [%s]\n" (i+1) (String.concat " | " values)
                      ) rows
                    );
                    Lwt.return_unit)
              with e ->
                Printf.printf "  ⚠️  Execution failed: %s\n" (Printexc.to_string e);
                Lwt.return_unit
            in
            Lwt.return_unit
          with e ->
            Printf.printf "  ❌ Translation failed: %s\n" (Printexc.to_string e);
            Lwt.return_unit
        in
        Printf.printf "\n";
        Lwt.return_unit
      ) srql_queries
    )
  )

let () = test_srql_with_simple_tables ()