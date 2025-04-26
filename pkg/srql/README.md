# ServiceRadar Query Language (SRQL)

A flexible, powerful query language for network monitoring, inspired by Armis ASQ/AQL.

## Overview

SRQL is a domain-specific query language that allows you to query network entities such as devices, flows, traps, and connections using a simple, readable syntax. It compiles to various database backends, including ClickHouse and ArangoDB.

## Example Queries

```
show devices where ip = '192.168.1.1'
find flows where bytes > 1000000 and dst_port = 80 order by bytes desc limit 10
count devices where traps.severity = 'critical' and os contains 'Windows'
```

## Getting Started

### Prerequisites

- Go 1.19 or later
- ANTLR4 tool (for generating parser code)

### Generate Parser Code

First, generate the parser code from the ANTLR grammar:

```bash
cd srql/antlr
antlr -Dlanguage=Go -package gen -o ../parser/gen ServiceRadarQueryLanguage.g4
```

## Using the Package

```go
package main

import (
    "fmt"
    "github.com/carverauto/serviceradar/pkg/srql/models"
    "github.com/carverauto/serviceradar/pkg/srql/parser"
)

func main() {
    // Create a parser
    p := parser.NewParser()
    
    // Parse a query
    query, err := p.Parse("show devices where ip = '192.168.1.1' and os contains 'Windows'")
    if err != nil {
        panic(err)
    }
    
    // Translate to a database query
    translator := parser.NewTranslator(parser.ClickHouse)
    sql, err := translator.Translate(query)
    if err != nil {
        panic(err)
    }
    
    fmt.Println(sql)
    // Output: SELECT * FROM devices WHERE ip = '192.168.1.1' AND position(os, 'Windows') > 0
}
```

## Features

- Natural, readable query syntax
- Support for multiple database backends
- Rich condition expressions (equality, comparison, contains, in, between, etc.)
- Order by and limit clauses
- Nested conditions with parentheses


## How to Use This Package in Your API

To use this package in your API, you would:

1. Generate the ANTLR parser first (follow instructions in the README)
2. Import the package in your API codebase
3. Use it to parse and translate network queries

Here's a quick example of how you might use it in your API:

```go
package api

import (
    "fmt"
    "net/http"
    "github.com/carverauto/serviceradar/pkg/srql/parser"
    
    "github.com/gin-gonic/gin" // Or your preferred framework
)

func setupQueryEndpoint(router *gin.Engine) {
    router.POST("/query", func(c *gin.Context) {
        var request struct {
            Query string `json:"query"`
        }
        
        if err := c.BindJSON(&request); err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request"})
            return
        }
        
        // Parse the query
        p := parser.NewParser()
        query, err := p.Parse(request.Query)
        if err != nil {
            c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("Query parsing error: %s", err)})
            return
        }
        
        // Translate to database query
        translator := parser.NewTranslator(parser.ClickHouse)
        dbQuery, err := translator.Translate(query)
        if err != nil {
            c.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to translate query"})
            return
        }
        
        // Execute the query against your database
        // This depends on your database drivers and implementation
        results, err := executeQuery(dbQuery)
        if err != nil {
            c.JSON(http.StatusInternalServerError, gin.H{"error": "Query execution failed"})
            return
        }
        
        c.JSON(http.StatusOK, results)
    })
}

func executeQuery(query string) (interface{}, error) {
    // Implement this based on your database setup
    // This could query ClickHouse, ArangoDB, etc.
    // ...
}
```