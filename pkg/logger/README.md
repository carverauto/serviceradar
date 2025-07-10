# Logger Package

This package provides JSON structured logging using [zerolog](https://github.com/rs/zerolog). It offers:

- JSON-formatted log output
- Configurable log levels
- Easy debug mode toggling
- Component-based logging
- Field-based enrichment

## Quick Start

### Basic Usage

```go
package main

import "github.com/carverauto/serviceradar/pkg/logger"

func main() {
    // Initialize with defaults (reads from environment variables)
    err := logger.InitWithDefaults()
    if err != nil {
        panic(err)
    }

    logger.Info().Msg("Application started")
    logger.Debug().Str("version", "1.0.0").Msg("Debug information")
}
```

### Custom Configuration

```go
config := logger.Config{
    Level:      "debug",
    Debug:      true,
    Output:     "stdout",
    TimeFormat: "",
}

err := logger.Init(config)
if err != nil {
    panic(err)
}
```

### Component-based Logging

```go
serviceLogger := logger.WithComponent("user-service")
serviceLogger.Info().
    Int("user_id", 12345).
    Str("action", "login").
    Msg("User authenticated")
```

### Field Logger Interface

```go
baseLogger := logger.GetLogger()
fieldLogger := logger.NewFieldLogger(baseLogger)

userLogger := fieldLogger.WithField("user_id", 12345)
userLogger.Info("User operation completed")

// With error
err := errors.New("connection failed")
userLogger.WithError(err).Error("Operation failed")
```

## Configuration

The logger can be configured through:

1. **Config struct**:
   - `Level`: Log level (trace, debug, info, warn, error, fatal, panic)
   - `Debug`: Boolean to enable debug mode
   - `Output`: Output destination (stdout, stderr)
   - `TimeFormat`: Custom time format (empty uses RFC3339)

2. **Environment variables**:
   - `LOG_LEVEL`: Set log level
   - `DEBUG`: Enable debug mode (true/false/1/0/yes/no/on/off)
   - `LOG_OUTPUT`: Set output destination
   - `LOG_TIME_FORMAT`: Custom time format

## Log Levels

- `trace`: Very detailed information
- `debug`: Debug information (only visible when debug mode is enabled)
- `info`: General information (default level)
- `warn`: Warning messages
- `error`: Error messages
- `fatal`: Fatal errors (calls os.Exit)
- `panic`: Panic messages (calls panic)

## Debug Mode

Debug mode can be toggled at runtime:

```go
logger.SetDebug(true)   // Enable debug logging
logger.SetDebug(false)  // Disable debug logging
```

## JSON Output Format

All logs are output in JSON format with these standard fields:

```json
{
  "level": "info",
  "time": "2025-01-10T10:30:00Z",
  "message": "User authenticated",
  "component": "user-service",
  "user_id": 12345
}
```

## Best Practices

1. **Use component loggers** for different parts of your application
2. **Add structured fields** rather than formatting messages
3. **Use appropriate log levels** - avoid logging sensitive information
4. **Initialize once** at application startup
5. **Use field loggers** for consistent field inclusion across related operations

## Thread Safety

The logger is thread-safe and can be used concurrently across goroutines.