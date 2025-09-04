# SRQL Translator

An OCaml-based translator for the ServiceRadar Query Language (SRQL) - a domain-specific language that compiles to SQL.

## Overview

SRQL provides a simplified, more intuitive syntax for querying data that gets translated into standard SQL. This project includes:
- A lexer and parser built with OCamllex and Menhir
- A REST API server built with Dream framework
- A command-line interface for direct translation
- Unit tests for the translator

## Features

- **Simple query syntax**: More readable than raw SQL
- **Three query types**: `show`, `find`, and `count`
- **Flexible conditions**: Support for AND/OR logic and multiple operators
- **REST API**: HTTP endpoint for integrating with other services
- **CLI tool**: Direct command-line translation

## Installation

### Prerequisites

```bash
# Install OPAM (OCaml package manager)
sh <(curl -sL https://raw.githubusercontent.com/ocaml/opam/master/shell/install.sh)

# Initialize OPAM
opam init
eval $(opam env)

# Install dependencies
opam install dune dream menhir yojson ppx_deriving lwt_ppx alcotest
```

### Build

```bash
# Clone the repository
git clone https://github.com/carverauto/serviceradar.git
cd serviceradar/ocaml

# Build the project
dune build

# Run tests
dune test
```

## Usage

### Web Server

Start the REST API server:

```bash
dune exec srql-translator
# Server runs on http://localhost:8080
```

Send translation requests:

```bash
curl -X POST http://localhost:8080/translate \
  -H "Content-Type: application/json" \
  -d '{"query": "find users where age > 21"}'

# Response:
# {"sql": "SELECT * FROM users WHERE age > 21"}
```

### Command Line Interface

```bash
# Build the CLI
dune exec srql-cli "show products"
# Output: SELECT * FROM products

# Or install it
dune install
srql-cli "count orders where status = 'pending'"
# Output: SELECT count() FROM orders WHERE status = 'pending'
```

## SRQL Syntax

### Query Types

- `show <entity>` - Returns all fields (translates to `SELECT *`)
- `find <entity>` - Same as show, semantic choice for searches
- `count <entity>` - Returns count (translates to `SELECT count()`)

### Operators

- `=` - Equal
- `!=` - Not equal
- `>` - Greater than
- `>=` - Greater than or equal
- `<` - Less than
- `<=` - Less than or equal
- `contains` - String contains (uses SQL position function)

### Logical Operators

- `and` - Logical AND
- `or` - Logical OR

### Examples

```sql
-- Simple queries
show users
→ SELECT * FROM users

find products limit 10
→ SELECT * FROM products LIMIT 10

count orders
→ SELECT count() FROM orders

-- With conditions
show employees where department = 'Engineering'
→ SELECT * FROM employees WHERE department = 'Engineering'

find products where price > 100 and category = 'Electronics'
→ SELECT * FROM products WHERE (price > 100 AND category = 'Electronics')

count users where created_date >= '2024-01-01' or status = 'active'
→ SELECT count() FROM users WHERE (created_date >= '2024-01-01' OR status = 'active')

-- String search
find articles where title contains 'OCaml'
→ SELECT * FROM articles WHERE position(title, 'OCaml') > 0

-- Complex query
find orders where (status = 'pending' or status = 'processing') and amount > 1000 limit 50
→ SELECT * FROM orders WHERE ((status = 'pending' OR status = 'processing') AND amount > 1000) LIMIT 50
```

## Project Structure

```
srql/
├── dune-project          # Project metadata
├── srql-translator.opam  # OPAM package definition
├── srql/
│   ├── bin/
│   │   ├── dune         # Binary targets configuration
│   │   ├── main.ml      # Web server entry point
│   │   └── cli.ml       # CLI entry point
│   ├── lib/
│   │   ├── dune         # Library configuration
│   │   ├── ast.ml       # Abstract Syntax Tree definitions
│   │   ├── lexer.mll    # Lexical analyzer
│   │   ├── parser.mly   # Grammar and parser
│   │   └── translator.ml # AST to SQL translator
│   └── test/
│       ├── dune         # Test configuration
│       └── test_translator.ml # Unit tests
```

## Development

### Running Tests

```bash
# Run all tests
dune test

# Run tests with output
dune test --force --no-buffer

# Run specific test file
dune exec srql/test/test_translator.exe
```

### Test Coverage

The comprehensive test suite includes 28 test cases covering:

- **Basic Queries** (3 tests): `show`, `find`, and `count` operations
- **WHERE Clauses** (7 tests): All comparison operators (`=`, `!=`, `>`, `>=`, `<`, `<=`, `contains`)
- **Logical Operators** (4 tests): `AND`/`OR` with proper operator precedence
- **LIMIT Clause** (2 tests): Simple limits and combined with WHERE conditions
- **Complex Queries** (2 tests): Multi-condition queries with mixed logical operators
- **Error Handling** (5 tests): Invalid syntax, missing entities, malformed queries
- **Edge Cases** (5 tests): Underscores in identifiers, mixed case, large numbers

Tests use the [Alcotest](https://github.com/mirage/alcotest) framework and verify both successful translations and proper error handling.

### Adding New Operators

1. Add token in `lexer.mll`
2. Add token declaration in `parser.mly`
3. Add to operator type in `ast.ml`
4. Update grammar rules in `parser.mly`
5. Add translation logic in `translator.ml`

### Grammar Extension Ideas

- `JOIN` operations
- `GROUP BY` and `HAVING` clauses
- `ORDER BY` clause
- Aggregate functions (`sum`, `avg`, `max`, `min`)
- Subqueries
- `IN` operator for list membership

## API Reference

### POST /translate

Translates an SRQL query to SQL.

**Request:**
```json
{
  "query": "find users where age > 21"
}
```

**Response (Success):**
```json
{
  "sql": "SELECT * FROM users WHERE age > 21"
}
```

**Response (Error):**
```json
{
  "error": "Syntax error near character 15"
}
```

### GET /health

Health check endpoint.

**Response:**
```json
{
  "status": "ok"
}
```

- Built with [Dream](https://aantron.github.io/dream/) web framework
- Parser generated with [Menhir](http://gallium.inria.fr/~fpottier/menhir/)
- JSON handling via [Yojson](https://github.com/ocaml-community/yojson)
