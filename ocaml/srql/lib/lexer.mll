{
  open Parser (* The tokens are defined in parser.mly *)
  exception Error of string
}

let digit = ['0'-'9']
let integer = digit+
let ident = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*

rule token = parse
  | [' ' '\t' '\r' '\n'] { token lexbuf } (* Skip whitespace *)
  | "show"      { SHOW }
  | "find"      { FIND }
  | "count"     { COUNT }
  | "where"     { WHERE }
  | "and"       { AND }
  | "or"        { OR }
  | "limit"     { LIMIT }
  | "contains"  { CONTAINS }
  | "="         { EQ }
  | "!="        { NEQ }
  | ">"         { GT }
  | ">="        { GTE }
  | "<"         { LT }
  | "<="        { LTE }
  | integer as i { INT (int_of_string i) }
  | "'" ([^'\'']*) "'" as s { STRING (String.sub s 1 (String.length s - 2)) }
  | ident as id { IDENT id }
  | eof         { EOF }
  | _ as c      { raise (Error (Printf.sprintf "Unexpected character: %c" c)) }
