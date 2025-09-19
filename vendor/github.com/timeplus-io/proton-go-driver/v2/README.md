# Proton Go Driver

## Introduction
[Proton](https://github.com/timeplus-io/proton) is a unified streaming and historical data processing engine in a single binary. The historical store is built based on [ClickHouse](https://github.com/ClickHouse/ClickHouse).

This project provides go driver to interact with Proton, the code is based on https://github.com/ClickHouse/clickhouse-go.

## Installation

To get started, you need to have Go installed. Then, import the Proton Database Go Driver using Go Modules:

```shell
go get github.com/timeplus-io/proton-go-driver/v2
```

## Quick Start

1. Run proton with docker, `docker run -d -p 8463:8463 --pull always --name proton ghcr.io/timeplus-io/proton:develop`
2. Run following Golang code

```go
package main

import (
	"fmt"
	"github.com/timeplus-io/proton-go-driver/v2"
)

func main() {
	conn := proton.OpenDB(&proton.Options{
		Addr: []string{"127.0.0.1:8463"},
		Auth: proton.Auth{
			Username: "default",
			Password: "",
		},
	})
	var value int
	conn.QueryRow("SELECT 300").Scan(&value)
	fmt.Println(value)
}
```

above code should return 1 , which shows that everything is working fine now.

## Connecting to Proton Database

To connect to the Proton database, create a connection using the following code:

```go
conn := proton.OpenDB(&proton.Options{
    Addr: []string{"127.0.0.1:8463"},
    Auth: proton.Auth{
        Database: "default",
        Username: "default",
        Password: "",
    },
    DialTimeout: 5 * time.Second,
    Compression: &proton.Compression{
        proton.CompressionLZ4,
    },
})
conn.SetMaxIdleConns(5)
conn.SetMaxOpenConns(10)
conn.SetConnMaxLifetime(time.Hour)
ctx = proton.Context(ctx, proton.WithProgress(func(p *proton.Progress) {
    if rand.Float32() < 0.3 {
        log.Println("progress:", p)
    }
}))
```

## Create Stream

Before working with streaming data, you need to initialize it. Here's an example for creating a stream:

```go
if _, err := conn.ExecContext(ctx, "DROP STREAM IF EXISTS car"); err != nil {
    return err
}
if _, err := conn.ExecContext(ctx, "CREATE STREAM IF NOT EXISTS car(id int64, speed float64)"); err != nil {
    return err
}
```
## Batch Insertion

```go
scope, err := conn.Begin()
if err != nil {
    log.Fatal(err)
}
batch, err := scope.PrepareContext(ctx, "INSERT INTO car (id, speed, _tp_time) values")
for i := 0; i < 20; i++ {
    speed := rand.Float64()*20 + 50
    _, err := batch.Exec(id, speed, time.Now())
    if err != nil {
        log.Fatal(err)
    }
    time.Sleep(time.Duration(100) * time.Millisecond)
}
err = scope.Commit()
if err != nil {
    log.Fatal(err)
}
```

## Streaming Query

```go
const QueryDDL = `SELECT id, avg(speed), window_start, window_end
    FROM session(car, 1h, [speed >= 60, speed < 60))
    GROUP BY id, window_start, window_end`
conn, ctx := getConnection(context.Background())
ctx, cancel := context.WithCancel(ctx)
rows, err := conn.QueryContext(ctx, QueryDDL)
if err != nil {
    log.Fatal(err)
}
defer rows.Close()
go func() {
    time.Sleep(time.Duration(20) * time.Second)
    cancel()
}()
for rows.Next() {
    var car SpeedingCarRcd
    if err := rows.Scan(&car.Id, &car.Speed, &car.Start, &car.End); err != nil {
        log.Fatal(err)
    }
    log.Printf("%+v", car)
}
err = rows.Err()
if err != nil {
    log.Fatal(err)
}
```

> [!NOTE]
> To cancel a streaming query, you need to use the cancel function returned by `context.WithCancel`.
