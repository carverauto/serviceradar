/* file: srql/lib/parser.mly */
%{
  open Ast
%}

/* Tokens with values */
%token <int> INT
%token <string> STRING
%token <string> IDENT

/* Keywords and operators */
%token SHOW FIND COUNT WHERE AND OR LIMIT
%token EQ NEQ GT GTE LT LTE CONTAINS
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
    { { q_type; entity; conditions = conds; limit = lim } }
;

query_type:
  | SHOW { `Show }
  | FIND { `Find }
  | COUNT { `Count }
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
;

value:
  | s = STRING { String s }
  | i = INT    { Int i }
;
