{
  open Parser (* The tokens are defined in parser.mly *)
  exception Error of string
}

let digit = ['0'-'9']
let integer = digit+
let ident = ['a'-'z' 'A'-'Z' '_'] ['a'-'z' 'A'-'Z' '0'-'9' '_']*

rule token = parse
  | [' ' '\t' '\r' '\n'] { token lexbuf } (* Skip whitespace *)
  | ("select" | "SELECT")   { SELECT }
  | ("from" | "FROM")       { FROM }
  | ("where" | "WHERE")     { WHERE }
  | ("and" | "AND")         { AND }
  | ("or" | "OR")           { OR }
  | ("limit" | "LIMIT")     { LIMIT }
  | ("order" | "ORDER")     { ORDER }
  | ("by" | "BY")           { BY }
  | ("group" | "GROUP")     { GROUP }
  | ("having" | "HAVING")   { HAVING }
  | ("asc" | "ASC")         { ASC }
  | ("desc" | "DESC")       { DESC }
  | ("as" | "AS")           { AS }
  | ("between" | "BETWEEN") { BETWEEN }
  | ("is" | "IS")           { IS }
  | ("null" | "NULL")       { NULL }
  | ("not" | "NOT")         { NOT }
  | ("latest" | "LATEST")   { LATEST }
  | ("contains" | "CONTAINS") { CONTAINS }
  | ("in" | "IN")           { IN }
  | ("like" | "LIKE")       { LIKE }
  | ("today" | "TODAY")     { TODAY }
  | ("yesterday" | "YESTERDAY") { YESTERDAY }
  | ("true" | "TRUE")       { TRUE }
  | ("false" | "FALSE")     { FALSE }
  | ("stream" | "STREAM")   { STREAM }
  | "="         { EQ }
  | "!="        { NEQ }
  | ">"         { GT }
  | ">="        { GTE }
  | "<"         { LT }
  | "<="        { LTE }
  | "("         { LPAREN }
  | ")"         { RPAREN }
  | ","         { COMMA }
  | "*"         { STAR }
  | integer as i { INT (int_of_string i) }
  | "'" ([^'\'']*) "'" as s { STRING (String.sub s 1 (String.length s - 2)) }
  | ident as id { IDENT id }
  | eof         { EOF }
  | _ as c      { raise (Error (Printf.sprintf "Unexpected character: %c" c)) }
