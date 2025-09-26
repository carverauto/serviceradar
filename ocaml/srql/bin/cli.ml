(* srql/bin/cli.ml - Command line interface for SRQL translator *)

let usage_msg = "srql-cli <query> - Translate SRQL (ASQ-aligned) to SQL"

module Translator = Srql_translator.Translator
module Client = Srql_translator.Proton_client.Client

let () =
  if Array.length Sys.argv < 2 then (
    Printf.eprintf "Usage: %s\n" usage_msg;
    Printf.eprintf "Example: srql-cli \"in:devices hostname:server time:today\"\n";
    exit 1);

  let query = Sys.argv.(1) in
  let translate (q : string) : (Translator.query_with_params, string) result =
    try
      let qspec = Srql_translator.Query_parser.parse q in
      match Srql_translator.Query_planner.plan_to_srql qspec with
      | None -> Error "Planning failed: please provide in:<entity> and attribute filters"
      | Some ast -> (
          match Srql_translator.Query_validator.validate ast with
          | Error msg -> Error msg
          | Ok () -> Ok (Translator.translate_query ast))
    with ex -> Error (Printexc.to_string ex)
  in
  match translate query with
  | Ok translation ->
      let sql = Client.substitute_params translation.sql translation.params in
      print_endline sql;
      if translation.params <> [] then (
        print_endline "-- Parameters:";
        List.iter
          (fun (name, value) ->
            Printf.printf "  %s = %s\n" name (Proton.Column.value_to_string value))
          translation.params)
  | Error msg ->
      Printf.eprintf "Error: %s\n" msg;
      exit 1
