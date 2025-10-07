let power10 p =
  let rec loop acc i = if i = 0 then acc else loop (Int64.mul acc 10L) (i - 1) in
  loop 1L p

let rfc3339_of_datetime ts =
  let tm = Unix.gmtime (Int64.to_float ts) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let rfc3339_of_datetime64 v precision =
  let denom = power10 precision in
  let secs = Int64.div v denom in
  let frac = Int64.rem v denom |> Int64.to_int in
  if precision <= 0 then rfc3339_of_datetime v
  else
    let base = rfc3339_of_datetime secs in
    let pad_left s width =
      let len = String.length s in
      if len >= width then s else String.make (width - len) '0' ^ s
    in
    let frac_str = pad_left (string_of_int frac) precision in
    let frac_str =
      let rec trim s =
        if s <> "" && s.[String.length s - 1] = '0' then trim (String.sub s 0 (String.length s - 1))
        else s
      in
      trim frac_str
    in
    if frac_str = "" then base else base ^ "." ^ frac_str

let rows_to_json ?(drop_cols = []) (rows, columns) : Yojson.Safe.t =
  let drop_has name = List.exists (fun n -> String.equal n name) drop_cols in
  let keep_cols = List.filter (fun (name, _typ) -> not (drop_has name)) columns in
  let keep_indices =
    List.mapi (fun i (name, _typ) -> if drop_has name then None else Some i) columns
    |> List.filter_map (fun x -> x)
  in

  let lc s = String.lowercase_ascii s in
  let trim s = String.trim s in
  let starts_with s pref =
    let s = lc (trim s) and p = lc pref in
    let ls = String.length s and lp = String.length p in
    ls >= lp && String.sub s 0 lp = p
  in
  let inner_of s =
    let s = trim s in
    try
      let i0 = String.index s '(' in
      let rec find_close i depth =
        if i >= String.length s then raise Not_found
        else
          let c = s.[i] in
          if c = '(' then find_close (i + 1) (depth + 1)
          else if c = ')' then if depth = 1 then i else find_close (i + 1) (depth - 1)
          else find_close (i + 1) depth
      in
      let j = find_close (i0 + 1) 1 in
      Some (String.sub s (i0 + 1) (j - (i0 + 1)))
    with _ -> None
  in
  let strip_wrapper wrapper s =
    if starts_with s (wrapper ^ "(") then
      match inner_of s with Some inn -> Some (trim inn) | None -> None
    else None
  in
  let rec strip_all_wrappers s =
    match strip_wrapper "nullable" s with
    | Some inner -> strip_all_wrappers inner
    | None -> (
        match strip_wrapper "lowcardinality" s with
        | Some inner -> strip_all_wrappers inner
        | None -> s)
  in
  let split_top_level_commas s =
    let s = trim s in
    let parts = ref [] in
    let buf = Buffer.create (String.length s) in
    let depth = ref 0 in
    let push_part () =
      parts := !parts @ [ Buffer.contents buf |> trim ];
      Buffer.clear buf
    in
    String.iter
      (fun c ->
        match c with
        | '(' ->
            depth := !depth + 1;
            Buffer.add_char buf c
        | ')' ->
            depth := !depth - 1;
            Buffer.add_char buf c
        | ',' when !depth = 0 -> push_part ()
        | _ -> Buffer.add_char buf c)
      s;
    push_part ();
    !parts
  in

  let rec pretty (typ : string) (v : Proton.Column.value) : Yojson.Safe.t =
    let lt = String.lowercase_ascii (String.trim typ) in
    let has sub =
      let ls = String.length lt and lsub = String.length sub in
      let rec loop i =
        if i + lsub > ls then false else if String.sub lt i lsub = sub then true else loop (i + 1)
      in
      loop 0
    in
    let s_val () = Proton.Column.value_to_string v in
    let nullable = has "nullable" in
    let is_null_string sv =
      let ls = String.lowercase_ascii (String.trim sv) in
      ls = "null" || sv = ""
    in
    match v with
    | Proton.Column.Null -> `Null
    | _ when nullable && is_null_string (s_val ()) -> `Null
    | Proton.Column.DateTime (ts, _) -> `String (rfc3339_of_datetime ts)
    | Proton.Column.DateTime64 (vv, p, _) -> `String (rfc3339_of_datetime64 vv p)
    | Proton.Column.Int32 i ->
        if lt = "bool" then `Bool (Int32.to_int i <> 0) else `Int (Int32.to_int i)
    | Proton.Column.UInt32 i ->
        if lt = "bool" then `Bool (Int32.to_int i <> 0)
        else
          let open Int64 in
          let v64 = logand (of_int32 i) 0xFFFF_FFFFL in
          `Int (to_int v64)
    | Proton.Column.Int64 i -> `Intlit (Int64.to_string i)
    | Proton.Column.UInt64 i -> `Intlit (Int64.to_string i)
    | Proton.Column.Float64 f -> if has "decimal" then `String (s_val ()) else `Float f
    | Proton.Column.Enum8 (name, _) -> `String name
    | Proton.Column.Enum16 (name, _) -> `String name
    | Proton.Column.Array arr ->
        let inner_typ =
          match strip_wrapper "array" lt with
          | Some inn -> strip_all_wrappers inn
          | None -> "string"
        in
        `List (Array.to_list arr |> List.map (pretty inner_typ))
    | Proton.Column.Map pairs ->
        let kt, vt =
          match strip_wrapper "map" lt with
          | Some inn -> (
              match split_top_level_commas inn with
              | k :: v :: _ -> (strip_all_wrappers k, strip_all_wrappers v)
              | _ -> ("string", "string"))
          | None -> ("string", "string")
        in
        let kv_list =
          List.map
            (fun (k, v) ->
              let k_json = pretty kt k in
              let key =
                match k_json with
                | `String s -> s
                | `Int n -> string_of_int n
                | `Float f -> string_of_float f
                | `Bool b -> if b then "true" else "false"
                | `Null -> "null"
                | other -> Yojson.Safe.to_string other
              in
              let v_json = pretty vt v in
              (key, v_json))
            pairs
        in
        `Assoc kv_list
    | Proton.Column.Tuple vs ->
        let tps =
          match strip_wrapper "tuple" lt with
          | Some inn -> split_top_level_commas inn |> List.map strip_all_wrappers
          | None -> []
        in
        let elems =
          match tps with
          | [] -> List.map (fun v -> `String (Proton.Column.value_to_string v)) vs
          | ts ->
              let rec map2 a b =
                match (a, b) with x :: xs, y :: ys -> pretty x y :: map2 xs ys | _ -> []
              in
              map2 ts vs
        in
        `List elems
    | Proton.Column.String s ->
        if lt = "bool" then
          match String.lowercase_ascii (String.trim s) with
          | "1" | "true" | "yes" -> `Bool true
          | _ -> `Bool false
        else if has "int64" || has "uint64" then `Intlit s
        else if has "int" || has "uint" then
          match int_of_string_opt s with Some n -> `Int n | None -> `Intlit s
        else if has "decimal" then `String s
        else if has "float" then
          match float_of_string_opt s with Some f -> `Float f | None -> `String s
        else `String s
  in

  let row_to_assoc row =
    let names_types = keep_cols in
    let values =
      List.map (fun idx -> try List.nth row idx with _ -> Proton.Column.String "") keep_indices
    in
    let pairs = List.map2 (fun (name, typ) v -> (name, pretty typ v)) names_types values in
    `Assoc pairs
  in
  `List (List.map row_to_assoc rows)
