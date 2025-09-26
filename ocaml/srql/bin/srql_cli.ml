open Lwt.Syntax

let print_usage () =
  print_endline "SRQL CLI - ServiceRadar Query Language Client";
  print_endline "";
  print_endline "Usage:";
  print_endline "  srql_cli [OPTIONS] <query>";
  print_endline "";
  print_endline "Options:";
  print_endline "  --host HOST        Proton host (default: serviceradar-proton)";
  print_endline "  --port PORT        Proton port (default: 8463)";
  print_endline "  --tls              Use TLS connection (default: false)";
  print_endline "  --tls-port PORT    TLS port (default: 9440)";
  print_endline "  --translate-only   Only translate SRQL to SQL, don't execute";
  print_endline "  --help             Show this help message";
  print_endline "";
  print_endline "Examples:";
  print_endline "  srql_cli 'SELECT * FROM events'";
  print_endline
    "  srql_cli --translate-only 'SELECT name, value FROM metrics WHERE timestamp > 1000'";
  print_endline "  srql_cli --tls 'SELECT COUNT(*) FROM logs'";
  exit 0

let parse_args () =
  let host = ref "serviceradar-proton" in
  let port = ref 8463 in
  let use_tls = ref false in
  let tls_port = ref 9440 in
  let translate_only = ref false in
  let query = ref "" in

  let args = Array.to_list Sys.argv in
  let rec parse = function
    | [] -> ()
    | "--help" :: _ | "-h" :: _ -> print_usage ()
    | "--host" :: h :: rest ->
        host := h;
        parse rest
    | "--port" :: p :: rest ->
        port := int_of_string p;
        parse rest
    | "--tls" :: rest ->
        use_tls := true;
        parse rest
    | "--tls-port" :: p :: rest ->
        tls_port := int_of_string p;
        parse rest
    | "--translate-only" :: rest ->
        translate_only := true;
        parse rest
    | q :: rest when String.length q > 0 && q.[0] <> '-' ->
        query := q;
        parse rest
    | _ :: rest -> parse rest
  in

  parse (List.tl args);

  if !query = "" then (
    print_endline "Error: No query provided";
    print_endline "";
    print_usage ());

  (!host, !port, !use_tls, !tls_port, !translate_only, !query)

let format_result _result =
  (* For now, just print the raw result *)
  (* In a real implementation, we'd format this nicely *)
  Printf.printf "Query executed successfully\n"

let main () =
  let host, port, use_tls, tls_port, translate_only, query = parse_args () in

  Printf.printf "SRQL Query: %s\n" query;

  if translate_only then (
    (* Just translate, don't execute *)
    try
      let translation = Srql_translator.Proton_client.SRQL.translate query in
      Printf.printf "Translated SQL: %s\n" translation.sql;
      (match translation.params with
      | [] -> ()
      | params ->
          print_endline "Parameters:";
          List.iter
            (fun (name, value) ->
              Printf.printf "  %s -> %s\n" name (Proton.Column.value_to_string value))
            params);
      Lwt.return_unit
    with e ->
      Printf.printf "Translation error: %s\n" (Printexc.to_string e);
      Lwt.return_unit)
  else
    (* Connect and execute *)
    let config =
      if use_tls then
        { Srql_translator.Proton_client.Config.local_docker_tls with host; port = tls_port }
      else { Srql_translator.Proton_client.Config.local_docker_no_tls with host; port }
    in

    Printf.printf "Connecting to %s:%d (TLS: %b)...\n" host
      (if use_tls then tls_port else port)
      use_tls;

    Srql_translator.Proton_client.Client.with_connection config (fun client ->
        let* result = Srql_translator.Proton_client.SRQL.translate_and_execute client query in
        format_result result;
        Lwt.return_unit)

let () =
  Lwt_main.run
    (try main ()
     with e ->
       Printf.printf "Error: %s\n" (Printexc.to_string e);
       Lwt.return_unit)
