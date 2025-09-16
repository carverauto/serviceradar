let contains_substring s sub =
  let len_s = String.length s and len_sub = String.length sub in
  let rec loop i =
    if i + len_sub > len_s then false
    else if String.sub s i len_sub = sub then true
    else loop (i + 1)
  in
  if len_sub = 0 then false else loop 0

let escape_string_literal (s : string) : string =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | '\'' -> Buffer.add_string buf "''"
      | '\\' -> Buffer.add_string buf "\\\\"
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let is_safe_identifier (s : string) : bool =
  let len = String.length s in
  if len = 0 then false
  else
    let first = s.[0] in
    let is_char_ok = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false in
    (match first with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
    && String.for_all is_char_ok s

let ensure_safe_identifier ~context (s : string) : string =
  let trimmed = String.trim s in
  if is_safe_identifier trimmed then trimmed
  else invalid_arg (Printf.sprintf "Invalid identifier for %s: '%s'" context s)

let ensure_safe_expression ~context (expr : string) : unit =
  let check_forbidden_char c = match c with '\000' | '\r' | '\n' -> true | _ -> false in
  if String.exists check_forbidden_char expr then
    invalid_arg (Printf.sprintf "Invalid characters in %s" context);
  if contains_substring expr ";" then invalid_arg (Printf.sprintf "Disallowed ';' in %s" context);
  if contains_substring expr "--" then invalid_arg (Printf.sprintf "Disallowed '--' in %s" context);
  if contains_substring expr "/*" then invalid_arg (Printf.sprintf "Disallowed '/*' in %s" context);
  if contains_substring expr "*/" then invalid_arg (Printf.sprintf "Disallowed '*/' in %s" context);
  if contains_substring expr "\\" then invalid_arg (Printf.sprintf "Disallowed '\\' in %s" context)
