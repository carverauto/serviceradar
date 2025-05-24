grammar ServiceRadarQueryLanguage;

// Parser Rules
query
    : showStatement
    | findStatement
    | countStatement
    | streamStatement
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

streamStatement
    : STREAM_KW (selectList)?
      FROM dataSource (joinPart)*
      (whereClause)?
      (groupByClause)?
      (havingClause)?
      (orderByClauseS)?
      (limitClauseS)?
      (emitClause)?
    ;

selectList
    : selectExpressionElement (COMMA selectExpressionElement)*
    | STAR
    ;

selectExpressionElement
    : expressionSelectItem (AS ID)?
    ;

expressionSelectItem
    : field
    | functionCall
    | value
    ;

functionCall
    : ID LPAREN (argumentList | STAR)? RPAREN // STAR for COUNT(*)
    ;

argumentList
    : expressionSelectItem (COMMA expressionSelectItem)*
    ;

dataSource
    : streamSourcePrimary (AS ID)?
    ;

streamSourcePrimary
    : (entity | ID)
    | TABLE_KW LPAREN (entity | ID) RPAREN
    | windowFunction LPAREN (entity | ID) COMMA field COMMA durationOrField (COMMA durationOrField)? RPAREN
    ;

windowFunction
    : TUMBLE
    | HOP
    ;

durationOrField
    : duration
    | field
    ;

duration
    : INTEGER (SECONDS_UNIT | MINUTES_UNIT | HOURS_UNIT | DAYS_UNIT)
    ;

joinPart
    : (joinType)? JOIN dataSource ON condition
    ;

joinType
    : LEFT | RIGHT | INNER
    ;

whereClause     : WHERE condition ;
groupByClause   : GROUP_KW BY fieldList ;
fieldList       : field (COMMA field)* ;
havingClause    : HAVING condition ;
orderByClauseS  : ORDER BY orderByItem (COMMA orderByItem)* ;
limitClauseS    : LIMIT INTEGER ;

emitClause
    : EMIT ( (AFTER WINDOW_KW CLOSE (WITH_KW DELAY duration)?) | (PERIODIC duration) )
    ;

entity
    : DEVICES
    | FLOWS
    | TRAPS
    | CONNECTIONS
    | LOGS
    | INTERFACES
    | SWEEP_RESULTS
    | ICMP_RESULTS
    | SNMP_RESULTS
    ;

condition
    : expression (logicalOperator expression)*
    ;

expression
    : evaluable comparisonOperator value // Changed 'field' to 'evaluable'
    | evaluable IN LPAREN valueList RPAREN
    | evaluable CONTAINS STRING
    | LPAREN condition RPAREN
    | evaluable BETWEEN value AND value
    | evaluable IS nullValue
    ;

evaluable
    : field
    | functionCall
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

// Current field rule. For more complex scenarios like 'source.table.field'
// you might consider generalizing to: field: ID (DOT ID)*;
// However, the current rule supports 'ID' which is needed for 'event_time' in window functions.
field
    : ID
    | entity DOT ID
    | entity DOT ID DOT ID
    ;

orderByClause // For SHOW/FIND statements
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
    | TODAY
    | YESTERDAY
    ;

LATEST_MODIFIER : L A T E S T ;

// -----------------------------------------------------------------------------
// Lexer Rules
// -----------------------------------------------------------------------------

SHOW : S H O W ;
FIND : F I N D ;
COUNT : C O U N T ;
WHERE : W H E R E ;
ORDER : O R D E R ;
BY : B Y ;
LIMIT : L I M I T ;
LATEST : L A T E S T ;
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
TODAY : T O D A Y ;
YESTERDAY : Y E S T E R D A Y ;

// --- Entity Type Keywords ---
DEVICES : D E V I C E S ;
FLOWS : F L O W S ;
TRAPS : T R A P S ;
CONNECTIONS : C O N N E C T I O N S ;
LOGS : L O G S ;
INTERFACES : I N T E R F A C E S ;
SWEEP_RESULTS : S W E E P '_' R E S U L T S ;
ICMP_RESULTS  : I C M P '_' R E S U L T S ;
SNMP_RESULTS  : S N M P '_' R E S U L T S ;

// --- New Keywords for Streaming and Joins ---
// Suffix _KW is used for common words to avoid potential clashes with identifiers
// or future language extensions if these words are used in other contexts.
STREAM_KW   : S T R E A M ;
FROM        : F R O M ;
TABLE_KW    : T A B L E ;
TUMBLE      : T U M B L E ;
HOP         : H O P ;
GROUP_KW    : G R O U P ;
HAVING      : H A V I N G ;
EMIT        : E M I T ;
AFTER       : A F T E R ;
WINDOW_KW   : W I N D O W ;
CLOSE       : C L O S E ;
WITH_KW     : W I T H ;
DELAY       : D E L A Y ;
PERIODIC    : P E R I O D I C ;
JOIN        : J O I N ;
ON          : O N ;
AS          : A S ;
LEFT        : L E F T ;
RIGHT       : R I G H T ;
INNER       : I N N E R ;
// OUTER    : O U T E R ; // Uncomment if needed

// --- Operators and Punctuation ---
EQ          : '=' | '==';
NEQ         : '!=' | '<>';
GT          : '>';
GTE         : '>=';
LT          : '<';
LTE         : '<=';
LIKE        : L I K E ;

BOOLEAN     : T R U E | F A L S E ;

DOT         : '.';
COMMA       : ',';
LPAREN      : '(';
RPAREN      : ')';
APOSTROPHE  : '\''; // Used by STRING, TIMESTAMP
QUOTE       : '"';  // Used by STRING
STAR        : '*' ;

// --- Time Unit Tokens ---
// These use the single-letter fragments defined below for case-insensitivity.
SECONDS_UNIT : S ;
MINUTES_UNIT : M ;
HOURS_UNIT   : H ;
DAYS_UNIT    : D ;

// --- Literals and Identifiers ---
ID          : [a-zA-Z_][a-zA-Z0-9_]*;
INTEGER     : [0-9]+;
FLOAT       : [0-9]+ '.' [0-9]*; // Allows .5 and 5.
STRING      : (QUOTE .*? QUOTE) | (APOSTROPHE .*? APOSTROPHE);
//TIMESTAMP   : APOSTROPHE [0-9][0-9][0-9][0-9] '-' [0-9][0-9] '-' [0-9][0-9] ' ' [0-9][0-9] ':' [0-9][0-9] ':' [0-9][0-9] APOSTROPHE;
//IPADDRESS   : [0-9]+ ('.' [0-9]+){3}; // More precise IP address regex
//MACADDRESS  : [0-9a-fA-F][0-9a-fA-F] (':' [0-9a-fA-F][0-9a-fA-F]){5}; // More precise MAC address regex
TIMESTAMP : APOSTROPHE [0-9][0-9][0-9][0-9] '-' [0-9][0-9] '-' [0-9][0-9] ' ' [0-9][0-9] ':' [0-9][0-9] ':' [0-9][0-9] APOSTROPHE;
IPADDRESS : [0-9]+ '.' [0-9]+ '.' [0-9]+ '.' [0-9]+;
MACADDRESS : [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F] ':' [0-9a-fA-F][0-9a-fA-F];


// --- Case-Insensitive Letter Fragments ---
// These are used to build the case-insensitive keywords above.
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

// --- Whitespace ---
WS  : [ \t\r\n]+ -> skip;