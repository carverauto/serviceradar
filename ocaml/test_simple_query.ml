open Lwt.Syntax

let test_simple_queries () =
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
      (* Only try very simple queries that don't involve complex table parsing *)
      let queries = [
        "SELECT 1";
        "SELECT 1 + 1";  
        "SELECT version()";
        "SELECT 'hello world'";
        "SELECT now()";
      ] in
      
      Lwt_list.iter_s (fun query ->
        Printf.printf "Testing query: %s\n" query;
        let* () = 
          try
            let* result = Srql_translator.Proton_client.Client.execute client query in
            (match result with
            | Proton.Client.NoRows ->
                Printf.printf "  ✅ Success (No rows)\n";
                Lwt.return_unit
            | Proton.Client.Rows (rows, columns) ->
                let row_count = List.length rows in
                let col_count = List.length columns in
                Printf.printf "  ✅ Success (%d rows, %d columns)\n" row_count col_count;
                (* Show first row data *)
                (match rows with
                | first_row :: _ ->
                    let values = List.map Proton.Column.value_to_string first_row in
                    Printf.printf "    First row: [%s]\n" (String.concat " | " values)
                | [] -> ());
                Lwt.return_unit)
          with e ->
            Printf.printf "  ❌ Failed: %s\n" (Printexc.to_string e);
            Lwt.return_unit
        in
        Printf.printf "\n";
        Lwt.return_unit
      ) queries
    )
  )

let () = test_simple_queries ()
