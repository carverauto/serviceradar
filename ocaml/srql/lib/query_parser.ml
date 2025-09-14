open Query_ast
open Ast

let split_ws (s:string) : string list =
  (* Split by whitespace but keep quoted segments "..." intact *)
  let len = String.length s in
  let buf = Buffer.create len in
  let parts = ref [] in
  let push () =
    let token = Buffer.contents buf |> String.trim in
    if token <> "" then parts := !parts @ [token];
    Buffer.clear buf
  in
  let rec loop i in_quotes =
    if i >= len then (push (); ()) else
    let c = s.[i] in
    match c, in_quotes with
    | '"', false -> loop (i+1) true
    | '"', true -> loop (i+1) false
    | (' ' | '\t' | '\n'), false -> push (); loop (i+1) false
    | _ -> Buffer.add_char buf c; loop (i+1) in_quotes
  in
  loop 0 false; !parts

let lower s = String.lowercase_ascii s
let trim s = String.trim s

let parse_kv (tok:string) : (string * string) option =
  match String.index_opt tok ':' with
  | None -> None
  | Some i ->
      let k = String.sub tok 0 i |> trim |> lower in
      let v = String.sub tok (i+1) (String.length tok - i - 1) |> trim in
      Some (k, v)

let parse_value (s:string) : Ast.value =
  match int_of_string_opt s with
  | Some n -> Int n
  | None ->
      let ls = lower s in
      if ls = "true" then Bool true
      else if ls = "false" then Bool false
      else String (if String.length s >= 2 && s.[0] = '"' && s.[String.length s - 1] = '"' then String.sub s 1 (String.length s - 2) else s)

let parse (input:string) : query_spec =
  let toks = split_ws input in
  let targets = ref [] in
  let filters = ref [] in
  let limit_ref = ref None in
  let sort_ref = ref None in
  let stream_ref = ref false in
  let window_ref = ref None in
  let stats_ref = ref None in
  let having_ref = ref None in
  List.iter (fun tok ->
    match parse_kv tok with
    | None -> ()
    | Some (k,v) -> (
        match k with
        | "in" ->
            let ents = v |> String.split_on_char ',' |> List.map (fun e -> e |> trim |> lower) in
            targets := !targets @ [Entity ents]
        | "observable" -> targets := !targets @ [Observable (lower v)]
        | "class" -> targets := !targets @ [EventClass (lower v)]
        | "value" -> filters := !filters @ [ObservableFilter ("value", parse_value v)]
        | "time" -> filters := !filters @ [TimeFilter v]
        | "limit" -> (match int_of_string_opt v with Some n -> limit_ref := Some n | None -> ())
        | "sort" ->
            let items = v |> String.split_on_char ',' |> List.filter ((<>) "") in
            let parsed = items |> List.map (fun it ->
              let it = trim it in
              match String.index_opt it ':' with
              | Some j ->
                  let f = String.sub it 0 j |> trim in
                  let d = String.sub it (j+1) (String.length it - j - 1) |> trim |> lower in
                  (f, if d = "desc" then Ast.Desc else Ast.Asc)
              | None -> (it, Ast.Asc)
            ) in
            sort_ref := Some parsed
        | "stream" | "mode" ->
            let lv = lower v in
            stream_ref := (lv = "1" || lv = "true" || lv = "stream")
        | "window" -> window_ref := Some v
        | "stats" -> stats_ref := Some v
        | "having" -> having_ref := Some v
        | key ->
          (* Attribute style: ip:1.2.3.4 hostname:foo *)
          filters := !filters @ [AttributeFilter (key, Eq, parse_value v)]
      )
  ) toks;
  {
    targets = !targets;
    filters = !filters;
    aggregations = None;
    limit = !limit_ref;
    sort = !sort_ref;
    stream = !stream_ref;
    window = !window_ref;
    stats = !stats_ref;
    having = !having_ref;
  }
