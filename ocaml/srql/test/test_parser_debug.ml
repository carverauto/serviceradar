let debug_lexer query =
  Printf.printf "Debugging lexer for: '%s'\n" query;
  let lexbuf = Lexing.from_string query in
  let rec print_tokens () =
    try
      let token = Srql_translator.Lexer.token lexbuf in
      match token with
      | Srql_translator.Parser.EOF -> 
          Printf.printf "  Token: EOF\n"
      | _ -> 
          Printf.printf "  Token: (some token)\n";
          print_tokens ()
    with
    | Srql_translator.Lexer.Error msg ->
        Printf.printf "  Lexer error: %s\n" msg
    | e ->
        Printf.printf "  Exception: %s\n" (Printexc.to_string e)
  in
  print_tokens ();
  Printf.printf "\n"

let test_simple_queries () =
  let queries = [
    "SELECT 1";
    "select 1";
    "SHOW devices";
    "show devices";
    "COUNT devices";
  ] in
  
  List.iter debug_lexer queries;
  
  Printf.printf "Now testing parsing:\n";
  List.iter (fun query ->
    Printf.printf "Parsing: '%s'\n" query;
    match Srql_translator.Translator.process_srql_string query with
    | Ok sql -> Printf.printf "  ✓ Success: %s\n" sql
    | Error msg -> Printf.printf "  ✗ Error: %s\n" msg;
    Printf.printf "\n"
  ) queries

let () =
  Printf.printf "🔍 SRQL Parser Debug Test\n";
  Printf.printf "========================\n\n";
  test_simple_queries ()