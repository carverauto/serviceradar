/* file: srql/lib/parser.mly */
%{
  open Ast
%}

/* Tokens with values */
%token <int> INT
%token <string> STRING
%token <string> IDENT
%token TRUE FALSE
%token TODAY YESTERDAY

/* Keywords and operators */
%token SELECT FROM WHERE AND OR LIMIT AS IN LIKE
%token ORDER BY ASC DESC
%token EQ NEQ GT GTE LT LTE CONTAINS ARRAY_CONTAINS
%token BETWEEN IS NULL NOT
%token GROUP HAVING LATEST
%token STREAM
%token LPAREN RPAREN COMMA STAR
%token EOF

/* Define operator precedence and associativity */
%left OR
%left AND

/* The entry point of the parser, it returns a value of type Ast.query */
%start <Ast.query> query

%%

/* Grammar rules */
query:
  | s = select_query; EOF { s }
  | st = stream_query; EOF { st }
;

select_query:
  | SELECT; fields = select_fields; from_clause = option(from_clause); conds = option(conditions); ord = option(order_clause); grp = option(group_clause); hav = option(having_clause); lim = option(limit_clause)
    { { q_type = `Select; entity = (match from_clause with Some e -> e | None -> ""); conditions = conds; limit = lim; select_fields = Some fields; order_by = ord; group_by = grp; having = hav; latest = false } }

stream_query:
  | STREAM; fields = select_fields; FROM; entity = IDENT; conds = option(conditions); grp = option(group_clause); hav = option(having_clause); ord = option(order_clause)
    { { q_type = `Stream; entity; conditions = conds; limit = None; select_fields = Some fields; order_by = ord; group_by = grp; having = hav; latest = false } }

opt_latest:
  | LATEST { true }
  | /* empty */ { false }
;

select_fields:
  | STAR { ["*"] }
  | field_list { $1 }
;

field_list:
  | field = IDENT { [field] }
  | literal = INT { [string_of_int literal] }
  | field = IDENT; COMMA; rest = field_list { field :: rest }
  | field = IDENT; AS; alias = IDENT { [field ^ " AS " ^ alias] }
  | field = IDENT; AS; alias = IDENT; COMMA; rest = field_list { (field ^ " AS " ^ alias) :: rest }
  | func = function_call { [func] }
  | func = function_call; COMMA; rest = field_list { func :: rest }
;

function_call:
  | name = IDENT; LPAREN; RPAREN { name ^ "()" }
  | name = IDENT; LPAREN; args = IDENT; RPAREN { name ^ "(" ^ args ^ ")" }
  | name = IDENT; LPAREN; args = INT; RPAREN { name ^ "(" ^ (string_of_int args) ^ ")" }
;

from_clause:
  | FROM; table = IDENT { table }
;

limit_clause:
  | LIMIT; n = INT { n }
;

conditions:
  | WHERE; c = condition { c }
;

order_clause:
  | ORDER; BY; lst = order_list { lst }
;

group_clause:
  | GROUP; BY; lst = field_list { lst }
;

having_clause:
  | HAVING; c = condition { c }
;

order_list:
  | field = IDENT; dir = opt_dir { [ (field, dir) ] }
  | field = IDENT; dir = opt_dir; COMMA; rest = order_list { (field, dir) :: rest }
;

opt_dir:
  | ASC { Ast.Asc }
  | DESC { Ast.Desc }
  | /* default ASC */ { Ast.Asc }
;

condition:
  | left = condition; AND; right = condition { And(left, right) }
  | left = condition; OR; right = condition  { Or(left, right) }
  | NOT; c = condition { Not c }
  | field = IDENT; BETWEEN; v1 = value; AND; v2 = value { Between(field, v1, v2) }
  | field = IDENT; IS; NULL { IsNull field }
  | field = IDENT; IS; NOT; NULL { IsNotNull field }
  | field = IDENT; IN; LPAREN; lst = value_list; RPAREN { InList(field, lst) }
  | field = IDENT; op = operator; v = value { Condition(field, op, v) }
;

operator:
  | EQ       { Eq }
  | NEQ      { Neq }
  | GT       { Gt }
  | GTE      { Gte }
  | LT       { Lt }
  | LTE      { Lte }
  | CONTAINS { Contains }
  | IN       { In }
  | LIKE     { Like }
  | ARRAY_CONTAINS { ArrayContains }
;

value:
  | s = STRING { String s }
  | i = INT    { Int i }
  | TRUE       { Bool true }
  | FALSE      { Bool false }
  | TODAY      { String "TODAY" }
  | YESTERDAY  { String "YESTERDAY" }
;

value_list:
  | v = value { [v] }
  | v = value; COMMA; rest = value_list { v :: rest }
