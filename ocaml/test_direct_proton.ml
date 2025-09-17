(* Direct test using Proton client library *)
open Proton

let () =
  Printf.printf "Testing direct Proton connection...\n";

  Lwt_main.run
    (let open Lwt.Syntax in
     (* Test with authentication *)
     let client =
       Client.create ~host:"localhost" ~port:8463 ~user:"default"
         ~password:"2fa7af883496fd7e5a8d222afe5d2dbf" ()
     in

     Printf.printf "Client created, attempting query...\n";

     let* res =
       Lwt.catch
         (fun () -> Client.execute client "SELECT 1 AS test, version() AS ver")
         (fun e ->
           Printf.printf "Query failed: %s\n" (Printexc.to_string e);
           Lwt.fail e)
     in

     (match res with
     | Client.NoRows -> Printf.printf "No rows returned\n"
     | Client.Rows (rows, columns) ->
         Printf.printf "Columns: ";
         List.iter (fun (name, typ) -> Printf.printf "%s:%s " name typ) columns;
         Printf.printf "\n";
         List.iter
           (fun row ->
             Printf.printf "Row: ";
             List.iter (fun v -> Printf.printf "%s " (Column.value_to_string v)) row;
             Printf.printf "\n")
           rows);

     let* () = Client.disconnect client in
     Printf.printf "✅ Test successful!\n";
     Lwt.return_unit)
