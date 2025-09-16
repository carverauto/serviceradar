val rows_to_json :
  ?drop_cols:string list -> Proton.Column.value list list * (string * string) list -> Yojson.Safe.t
(* Convert Proton rows and columns to typed JSON array. The tuple is (rows, columns) matching Proton.Client.Rows structure,
   but passed in decomposed to avoid coupling to client type. drop_cols removes helper columns from output. *)
