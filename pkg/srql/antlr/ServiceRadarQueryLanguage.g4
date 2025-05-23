grammar ServiceRadarQueryLanguage;

// Parser Rules
query
    : showStatement
    | findStatement
    | countStatement
    ;

showStatement
    : SHOW entity (WHERE condition)? (ORDER BY orderByClause)? (LIMIT INTEGER)? (LATEST_MODIFIER)?
    ;

findStatement
    : FIND entity (WHERE condition)? (ORDER BY orderByClause)? (LIMIT INTEGER)? (LATEST_MODIFIER)?
    ;

countStatement
    : COUNT entity (WHERE condition)?
    ;

entity
    : DEVICES
    | FLOWS
    | TRAPS
    | CONNECTIONS
    | LOGS
    | INTERFACES
    ;

condition
    : expression (logicalOperator expression)*
    ;

expression
    : field comparisonOperator value
    | field IN LPAREN valueList RPAREN
    | field CONTAINS STRING
    | LPAREN condition RPAREN
    | field BETWEEN value AND value
    | field IS nullValue
    ;

valueList
    : value (COMMA value)*
    ;

logicalOperator
    : AND
    | OR
    ;

comparisonOperator
    : EQ
    | NEQ
    | GT
    | GTE
    | LT
    | LTE
    | LIKE
    ;

nullValue
    : NULL
    | NOT NULL
    ;

field
    : ID
    | entity DOT ID
    | entity DOT ID DOT ID
    ;

orderByClause
    : orderByItem (COMMA orderByItem)*
    ;

orderByItem
    : field (ASC | DESC)?
    ;

value
    : STRING
    | INTEGER
    | FLOAT
    | BOOLEAN
    | TIMESTAMP
    | IPADDRESS
    | MACADDRESS
    ;

LATEST_MODIFIER : L A T E S T ; // Defined as a distinct rule for semantic clarity

// Lexer Rules - All case insensitive
SHOW : S H O W ;
FIND : F I N D ;
COUNT : C O U N T ;
WHERE : W H E R E ;
ORDER : O R D E R ;
BY : B Y ;
LIMIT : L I M I T ;
LATEST : L A T E S T ; // The token itself
ASC : A S C ;
DESC : D E S C ;
AND : A N D ;
OR : O R ;
IN : I N ;
BETWEEN : B E T W E E N ;
CONTAINS : C O N T A I N S ;
IS : I S ;
NOT : N O T ;
NULL : N U L L ;

DEVICES : D E V I C E S ;
FLOWS : F L O W S ;
TRAPS : T R A P S ;
CONNECTIONS : C O N N E C T I O N S ;
LOGS : L O G S ;
INTERFACES : I N T E R F A C E S ;

EQ : '=' | '==';
NEQ : '!=' | '<>';
GT : '>';
GTE : '>=';
LT : '<';
LTE : '<=';
LIKE : L I K E ;

BOOLEAN : T R U E | F A L S E ;

DOT : '.';
COMMA : ',';
LPAREN : '(';
RPAREN : ')';
APOSTROPHE : '\'';
QUOTE : '"';

ID : [a-zA-Z_][a-zA-Z0-9_]*;
INTEGER : [0-9]+;
FLOAT : [0-9]+ '.' [0-9]*;
STRING : (QUOTE .*? QUOTE) | (APOSTROPHE .*? APOSTROPHE);

// Fixed the problematic lexer rules by removing implicit actions
TIMESTAMP : APOSTROPHE [0-9][0-9][0-9][0-9] '-' [0-9][0-9] '-' [0-9][0-9] ' ' [0-9][0-9] ':' [0-9][0-9] ':' [0-9][0-9] APOSTROPHE;
IPADDRESS : [0-9]+ '.' [0-9]+ '.' [0-9]+ '.' [0-9]+;
MACADDRESS : [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F];

// Fragment rules for case insensitivity
fragment A : [aA];
fragment B : [bB];
fragment C : [cC];
fragment D : [dD];
fragment E : [eE];
fragment F : [fF];
fragment G : [gG];
fragment H : [hH];
fragment I : [iI];
fragment J : [jJ];
fragment K : [kK];
fragment L : [lL];
fragment M : [mM];
fragment N : [nN];
fragment O : [oO];
fragment P : [pP];
fragment Q : [qQ];
fragment R : [rR];
fragment S : [sS];
fragment T : [tT];
fragment U : [uU];
fragment V : [vV];
fragment W : [wW];
fragment X : [xX];
fragment Y : [yY];
fragment Z : [zZ];

WS : [ \t\r\n]+ -> skip;