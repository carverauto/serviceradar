(* srql/test/test_translator.ml - Unit tests for SRQL translator *)

open Alcotest

(* Helper function to test translation *)
let test_translation input expected () =
  match Srql_translator.Translator.process_srql_string input with
  | Ok result -> 
      check string "translation" expected result
  | Error msg -> 
      fail (Printf.sprintf "Translation failed for '%s': %s" input msg)

(* Helper function to test that translation fails *)
let make_error_test input () =
  match Srql_translator.Translator.process_srql_string input with
  | Ok result -> 
      fail (Printf.sprintf "Expected error for '%s' but got: %s" input result)
  | Error _ -> 
      ()

(* Test basic queries *)
let test_basic_show () =
  test_translation "show users" "SELECT * FROM users" ()

let test_basic_find () =
  test_translation "find products" "SELECT * FROM products" ()

let test_basic_count () =
  test_translation "count orders" "SELECT count() FROM orders" ()

(* Test queries with simple WHERE clauses *)
let test_where_equals () =
  test_translation 
    "show users where name = 'John'" 
    "SELECT * FROM users WHERE name = 'John'" ()

let test_where_not_equals () =
  test_translation 
    "find products where category != 'Electronics'"
    "SELECT * FROM products WHERE category != 'Electronics'" ()

let test_where_greater_than () =
  test_translation 
    "show orders where amount > 1000"
    "SELECT * FROM orders WHERE amount > 1000" ()

let test_where_greater_equals () =
  test_translation 
    "count users where age >= 18"
    "SELECT count() FROM users WHERE age >= 18" ()

let test_where_less_than () =
  test_translation 
    "find items where price < 50"
    "SELECT * FROM items WHERE price < 50" ()

let test_where_less_equals () =
  test_translation 
    "show employees where years <= 5"
    "SELECT * FROM employees WHERE years <= 5" ()

(* Test CONTAINS operator *)
let test_contains () =
  test_translation 
    "find articles where title contains 'OCaml'"
    "SELECT * FROM articles WHERE position(title, 'OCaml') > 0" ()

(* Test logical operators *)
let test_and_operator () =
  test_translation 
    "show users where age > 21 and status = 'active'"
    "SELECT * FROM users WHERE (age > 21 AND status = 'active')" ()

let test_or_operator () =
  test_translation 
    "find products where category = 'Books' or category = 'Music'"
    "SELECT * FROM products WHERE (category = 'Books' OR category = 'Music')" ()

let test_complex_logical () =
  test_translation 
    "count orders where status = 'pending' and amount > 100 or priority = 'high'"
    "SELECT count() FROM orders WHERE ((status = 'pending' AND amount > 100) OR priority = 'high')" ()

(* Test LIMIT clause *)
let test_limit () =
  test_translation 
    "show products limit 10"
    "SELECT * FROM products LIMIT 10" ()

let test_where_with_limit () =
  test_translation 
    "find users where age > 18 limit 100"
    "SELECT * FROM users WHERE age > 18 LIMIT 100" ()

(* Test ORDER BY clause *)
let test_order_by_single_asc () =
  test_translation
    "show users order by created_at asc limit 5"
    "SELECT * FROM users ORDER BY created_at ASC LIMIT 5" ()

let test_order_by_single_default_asc () =
  test_translation
    "find logs order by timestamp limit 10"
    "SELECT * FROM logs ORDER BY timestamp ASC LIMIT 10" ()

let test_order_by_multi_mixed_dirs () =
  test_translation
    "count events where severity = 'ERROR' order by timestamp desc, id asc limit 1"
    "SELECT count() FROM events WHERE severity = 'ERROR' ORDER BY timestamp DESC, id ASC LIMIT 1" ()

let test_select_with_order_by () =
  test_translation
    "select name, value from metrics where host = 'a' order by timestamp desc limit 2"
    "SELECT name, value FROM metrics WHERE host = 'a' ORDER BY timestamp DESC LIMIT 2" ()

(* Test complex queries *)
let test_complex_query_1 () =
  test_translation 
    "find orders where status = 'processing' and amount >= 500 and customer_id = 42 limit 20"
    "SELECT * FROM orders WHERE ((status = 'processing' AND amount >= 500) AND customer_id = 42) LIMIT 20" ()

let test_complex_query_2 () =
  test_translation 
    "count logs where severity = 'ERROR' or severity = 'CRITICAL' and timestamp > 1234567890"
    "SELECT count() FROM logs WHERE (severity_text = 'ERROR' OR (severity_text = 'CRITICAL' AND timestamp > 1234567890))" ()

(* Test parentheses in conditions *)
let test_parentheses_precedence () =
  test_translation
    "show items where category = 'A' or category = 'B' and price > 100"
    "SELECT * FROM items WHERE (category = 'A' OR (category = 'B' AND price > 100))" ()

(* Test error cases *)
let test_empty_query () =
  make_error_test "" ()

let test_invalid_syntax () =
  (* Ensure parser rejects malformed SELECT lacking fields *)
  make_error_test "select from users" ()

let test_missing_entity () =
  make_error_test "show" ()

let test_invalid_operator () =
  make_error_test "show users where age ~ 21" ()

let test_unclosed_string () =
  make_error_test "show users where name = 'John" ()

(* Test integer values *)
let test_integer_values () =
  test_translation 
    "find products where quantity = 0"
    "SELECT * FROM products WHERE quantity = 0" ()

let test_large_integer () =
  test_translation 
    "show transactions where amount > 1000000"
    "SELECT * FROM transactions WHERE amount > 1000000" ()

(* Test edge cases *)
let test_table_with_underscore () =
  test_translation 
    "show user_profiles"
    "SELECT * FROM user_profiles" ()

let test_column_with_underscore () =
  test_translation 
    "find orders where created_at > 1234567890"
    "SELECT * FROM orders WHERE created_at > 1234567890" ()

let test_mixed_case_identifiers () =
  test_translation 
    "show UserProfiles where isActive = 1"
    "SELECT * FROM UserProfiles WHERE isactive = 1" ()

(* Test suites *)
let basic_queries = [
  "show query", `Quick, test_basic_show;
  "find query", `Quick, test_basic_find;
  "count query", `Quick, test_basic_count;
]

let where_clauses = [
  "equals operator", `Quick, test_where_equals;
  "not equals operator", `Quick, test_where_not_equals;
  "greater than operator", `Quick, test_where_greater_than;
  "greater equals operator", `Quick, test_where_greater_equals;
  "less than operator", `Quick, test_where_less_than;
  "less equals operator", `Quick, test_where_less_equals;
  "contains operator", `Quick, test_contains;
]

let logical_operators = [
  "AND operator", `Quick, test_and_operator;
  "OR operator", `Quick, test_or_operator;
  "complex logical expressions", `Quick, test_complex_logical;
  "operator precedence", `Quick, test_parentheses_precedence;
]

let limit_clause = [
  "simple limit", `Quick, test_limit;
  "where with limit", `Quick, test_where_with_limit;
]

let order_by_clause = [
  "order by single asc", `Quick, test_order_by_single_asc;
  "order by single default asc", `Quick, test_order_by_single_default_asc;
  "order by multi mixed", `Quick, test_order_by_multi_mixed_dirs;
  "select with order by", `Quick, test_select_with_order_by;
]

let complex_queries = [
  "complex query 1", `Quick, test_complex_query_1;
  "complex query 2", `Quick, test_complex_query_2;
]

let error_handling = [
  "empty query", `Quick, test_empty_query;
  "invalid syntax", `Quick, test_invalid_syntax;
  "missing entity", `Quick, test_missing_entity;
  "invalid operator", `Quick, test_invalid_operator;
  "unclosed string", `Quick, test_unclosed_string;
]

let edge_cases = [
  "integer value", `Quick, test_integer_values;
  "large integer", `Quick, test_large_integer;
  "table with underscore", `Quick, test_table_with_underscore;
  "column with underscore", `Quick, test_column_with_underscore;
  "mixed case identifiers", `Quick, test_mixed_case_identifiers;
]

(* Main test runner *)
let () =
  run "SRQL Translator Tests" [
    "Basic Queries", basic_queries;
    "WHERE Clauses", where_clauses;
    "Logical Operators", logical_operators;
    "LIMIT Clause", limit_clause;
    "ORDER BY Clause", order_by_clause;
    "Complex Queries", complex_queries;
    "Error Handling", error_handling;
    "Edge Cases", edge_cases;
  ]
