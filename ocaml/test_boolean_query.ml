let () =
  let query = "COUNT devices WHERE is_available = true" in
  Printf.printf "Testing: %s\n" query;
  match Srql_translator.Translator.process_srql_string query with
  | Ok sql -> Printf.printf "Success: %s\n" sql
  | Error msg -> Printf.printf "Error: %s\n" msg
