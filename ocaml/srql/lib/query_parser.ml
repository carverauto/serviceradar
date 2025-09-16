open Query_ast
open Sql_ir

let lower s = String.lowercase_ascii s
let trim s = String.trim s

(* Tokenize while respecting quotes and balanced parentheses. Splits on whitespace only at depth 0. *)
let tokenize (s : string) : string list =
  let len = String.length s in
  let buf = Buffer.create len in
  let parts = ref [] in
  let push () =
    let tok = Buffer.contents buf |> String.trim in
    if tok <> "" then parts := !parts @ [ tok ];
    Buffer.clear buf
  in
  let rec loop i depth in_quotes =
    if i >= len then (
      push ();
      ())
    else
      let c = s.[i] in
      match (c, in_quotes, depth) with
      | '"', false, _ ->
          Buffer.add_char buf c;
          loop (i + 1) depth true
      | '"', true, _ ->
          Buffer.add_char buf c;
          loop (i + 1) depth false
      | '(', _, _ ->
          Buffer.add_char buf c;
          loop (i + 1) (depth + 1) in_quotes
      | ')', _, _ ->
          Buffer.add_char buf c;
          loop (i + 1) (max 0 (depth - 1)) in_quotes
      | (' ' | '\t' | '\n'), false, 0 ->
          push ();
          loop (i + 1) depth in_quotes
      | _ ->
          Buffer.add_char buf c;
          loop (i + 1) depth in_quotes
  in
  loop 0 0 false;
  !parts

let strip_quotes (s : string) : string =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n - 1] = '"' then String.sub s 1 (n - 2) else s

let parse_value (s : string) : Sql_ir.value =
  let s = strip_quotes s in
  match int_of_string_opt s with
  | Some n -> Int n
  | None ->
      let ls = lower s in
      if ls = "true" then Bool true else if ls = "false" then Bool false else String s

let parse_kv (tok : string) : (string * string) option =
  match String.index_opt tok ':' with
  | None -> None
  | Some i ->
      let k = String.sub tok 0 i |> trim |> lower in
      let v = String.sub tok (i + 1) (String.length tok - i - 1) |> trim in
      Some (k, v)

let strip_neg (k : string) : bool * string =
  if String.length k > 0 && k.[0] = '!' then (true, String.sub k 1 (String.length k - 1) |> trim)
  else (false, k)

(* Parse a comma-separated value list respecting quotes *)
let split_csv_top (s : string) : string list =
  let len = String.length s in
  let buf = Buffer.create len in
  let parts = ref [] in
  let in_quotes = ref false in
  let push () =
    let v = Buffer.contents buf |> String.trim in
    if v <> "" then parts := !parts @ [ v ];
    Buffer.clear buf
  in
  for i = 0 to len - 1 do
    let c = s.[i] in
    match (c, !in_quotes) with
    | '"', false ->
        in_quotes := true;
        Buffer.add_char buf c
    | '"', true ->
        in_quotes := false;
        Buffer.add_char buf c
    | ',', false -> push ()
    | _ -> Buffer.add_char buf c
  done;
  push ();
  !parts

(* Recursively parse a parenthesized group. Returns flattened Attribute filters. *)
let rec parse_group ~prefix ?(neg = false) (body : string) : Query_ast.search_filter list =
  (* If body contains ':' tokens, treat as nested KVs split by whitespace at depth 0. Otherwise, treat as CSV list. *)
  let contains_colon = String.index_opt body ':' <> None in
  if not contains_colon then
    let values = split_csv_top body |> List.map parse_value in
    match values with
    | [] -> []
    | [ _ ] ->
        if neg then [ AttributeFilter (prefix, Neq, List.hd values) ]
        else [ AttributeFilter (prefix, Eq, List.hd values) ]
    | vs ->
        if neg then [ AttributeListFilterNot (prefix, vs) ]
        else [ AttributeListFilter (prefix, vs) ]
  else
    let toks = tokenize body in
    toks
    |> List.fold_left
         (fun acc tok ->
           match parse_kv tok with
           | None -> acc
           | Some (k, v) ->
               let neg_k, k_stripped = strip_neg k in
               let full_k = if prefix = "" then k_stripped else prefix ^ "." ^ k_stripped in
               let neg_eff = neg || neg_k in
               (* If v is a parenthesized sub-expression, recurse; otherwise simple value or CSV list *)
               let v = strip_quotes v in
               if String.length v >= 2 && v.[0] = '(' && v.[String.length v - 1] = ')' then
                 let inner = String.sub v 1 (String.length v - 2) in
                 acc @ parse_group ~prefix:full_k ~neg:neg_eff inner
               else if String.contains v ',' then
                 let vs = split_csv_top v |> List.map parse_value in
                 if List.length vs = 1 then
                   acc @ [ AttributeFilter (full_k, (if neg_eff then Neq else Eq), List.hd vs) ]
                 else
                   acc
                   @ [
                       (if neg_eff then AttributeListFilterNot (full_k, vs)
                        else AttributeListFilter (full_k, vs));
                     ]
               else acc @ [ AttributeFilter (full_k, (if neg_eff then Neq else Eq), parse_value v) ])
         []

let parse_timeframe (s : string) : string option =
  (* Map "7 Days" -> last_7d, "1 Day" -> last_1d, "12 Hours" -> last_12h, "30 Minutes" -> last_30m, "2 Weeks" -> last_2w *)
  let s = strip_quotes s |> String.trim |> lower in
  let ws = s |> String.split_on_char ' ' |> List.filter (( <> ) "") in
  match ws with
  | [ n_str; unit ] -> (
      match int_of_string_opt n_str with
      | None -> None
      | Some n ->
          let starts_with pref =
            let lp = String.length pref in
            String.length unit >= lp && String.sub unit 0 lp = pref
          in
          let u =
            if starts_with "day" then "d"
            else if starts_with "hour" then "h"
            else if starts_with "minute" then "m"
            else if starts_with "week" then "w"
            else ""
          in
          if u = "" then None else Some (Printf.sprintf "last_%d%s" n u))
  | _ -> None

let parse (input : string) : query_spec =
  let toks = tokenize input in
  let targets = ref [] in
  let filters = ref [] in
  let limit_ref = ref None in
  let sort_ref = ref None in
  let stream_ref = ref false in
  let window_ref = ref None in
  let stats_ref = ref None in
  let having_ref = ref None in
  List.iter
    (fun tok ->
      match parse_kv tok with
      | None ->
          (* allow bare "inactivity" as alias for in:activity *)
          let lt = lower tok in
          if lt = "inactivity" then targets := !targets @ [ Entity [ "activity" ] ]
      | Some (k, v) -> (
          match k with
          | "in" ->
              let ents = v |> String.split_on_char ',' |> List.map (fun e -> e |> trim |> lower) in
              targets := !targets @ [ Entity ents ]
          | "observable" -> targets := !targets @ [ Observable (lower v) ]
          | "class" -> targets := !targets @ [ EventClass (lower v) ]
          | "value" -> filters := !filters @ [ ObservableFilter ("value", parse_value v) ]
          | "time" -> filters := !filters @ [ TimeFilter v ]
          | "timeframe" -> (
              match parse_timeframe v with
              | Some s -> filters := !filters @ [ TimeFilter s ]
              | None -> filters := !filters @ [ TimeFilter v ])
          | "limit" -> (
              match int_of_string_opt (strip_quotes v) with
              | Some n -> limit_ref := Some n
              | None -> ())
          | "sort" ->
              let items =
                v |> strip_quotes |> String.split_on_char ',' |> List.filter (( <> ) "")
              in
              let parsed =
                items
                |> List.map (fun it ->
                       let it = trim it in
                       match String.index_opt it ':' with
                       | Some j ->
                           let f = String.sub it 0 j |> trim in
                           let d =
                             String.sub it (j + 1) (String.length it - j - 1) |> trim |> lower
                           in
                           (f, if d = "desc" then Sql_ir.Desc else Sql_ir.Asc)
                       | None -> (it, Sql_ir.Asc))
              in
              sort_ref := Some parsed
          | "stream" | "mode" ->
              let lv = lower (strip_quotes v) in
              stream_ref := lv = "1" || lv = "true" || lv = "stream"
          | "window" -> window_ref := Some (strip_quotes v)
          | "stats" -> stats_ref := Some (strip_quotes v)
          | "having" -> having_ref := Some (strip_quotes v)
          | key ->
              let neg_key, key' = strip_neg key in
              let vstr = strip_quotes v in
              if String.length vstr >= 2 && vstr.[0] = '(' && vstr.[String.length vstr - 1] = ')'
              then
                let inner = String.sub vstr 1 (String.length vstr - 2) in
                filters := !filters @ parse_group ~prefix:key' ~neg:neg_key inner
              else if String.contains vstr ',' then
                let vs = split_csv_top vstr |> List.map parse_value in
                filters :=
                  !filters
                  @ [
                      (if neg_key then AttributeListFilterNot (key', vs)
                       else AttributeListFilter (key', vs));
                    ]
              else
                filters :=
                  !filters
                  @ [ AttributeFilter (key', (if neg_key then Neq else Eq), parse_value v) ]))
    toks;
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
