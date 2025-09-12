/* file: srql/lib/parser.mly */
%{
  open Ast
%}

/* Tokens with values */
%token <int> INT
%token <string> STRING
%token <string> IDENT
%token TRUE FALSE

/* Keywords and operators */
%token SHOW FIND COUNT SELECT FROM WHERE AND OR LIMIT AS IN LIKE
%token EQ NEQ GT GTE LT LTE CONTAINS ARRAY_CONTAINS
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
  | q_type = query_type; entity = IDENT; conds = option(conditions); lim = option(limit_clause); EOF
    { { q_type; entity; conditions = conds; limit = lim; select_fields = None } }
  | SELECT; fields = select_fields; from_clause = option(from_clause); conds = option(conditions); lim = option(limit_clause); EOF
    { { q_type = `Select; entity = (match from_clause with Some e -> e | None -> ""); conditions = conds; limit = lim; select_fields = Some fields } }
;

query_type:
  | SHOW { `Show }
  | FIND { `Find }
  | COUNT { `Count }
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

condition:
  | left = condition; AND; right = condition { And(left, right) }
  | left = condition; OR; right = condition  { Or(left, right) }
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
;
