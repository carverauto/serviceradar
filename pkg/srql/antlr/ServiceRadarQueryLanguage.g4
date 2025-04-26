grammar ServiceRadarQueryLanguage;

// Parser Rules
query
    : showStatement
    | findStatement
    | countStatement
    ;

showStatement
    : SHOW entity (WHERE condition)? (ORDER BY orderByClause)? (LIMIT INTEGER)?
    ;

findStatement
    : FIND entity (WHERE condition)? (ORDER BY orderByClause)? (LIMIT INTEGER)?
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

// Lexer Rules
SHOW : 'show' | 'SHOW';
FIND : 'find' | 'FIND';
COUNT : 'count' | 'COUNT';
WHERE : 'where' | 'WHERE';
ORDER : 'order' | 'ORDER';
BY : 'by' | 'BY';
LIMIT : 'limit' | 'LIMIT';
ASC : 'asc' | 'ASC';
DESC : 'desc' | 'DESC';
AND : 'and' | 'AND';
OR : 'or' | 'OR';
IN : 'in' | 'IN';
BETWEEN : 'between' | 'BETWEEN';
CONTAINS : 'contains' | 'CONTAINS';
IS : 'is' | 'IS';
NOT : 'not' | 'NOT';
NULL : 'null' | 'NULL';

DEVICES : 'devices' | 'DEVICES';
FLOWS : 'flows' | 'FLOWS';
TRAPS : 'traps' | 'TRAPS';
CONNECTIONS : 'connections' | 'CONNECTIONS';
LOGS : 'logs' | 'LOGS';

EQ : '=' | '==';
NEQ : '!=' | '<>';
GT : '>';
GTE : '>=';
LT : '<';
LTE : '<=';
LIKE : 'like' | 'LIKE';

BOOLEAN : 'true' | 'TRUE' | 'false' | 'FALSE';

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

WS : [ \t\r\n]+ -> skip;