---
sidebar_position: 7
title: Creating a Custom Checker Plugin
---

# Creating a Custom Checker Plugin for ServiceRadar

ServiceRadar's modular architecture allows you to extend its monitoring capabilities by creating custom checkers (plugins). These checkers integrate with the Agent to monitor specific services or systems and report their status via gRPC. This tutorial walks you through the process of creating, packaging, and deploying a custom checker plugin, using the existing Dusk checker as an example.

## Overview

A checker plugin in ServiceRadar is a standalone binary that:

- Implements the Checker interface (and optionally StatusProvider or HealthChecker) from the checker package
- Communicates with the Agent via gRPC or other supported protocols
- Can be configured via JSON files in `/etc/serviceradar/checkers/`
- Runs as a systemd service for continuous operation

This guide covers:
- Understanding the checker architecture
- Writing a custom checker in Go
- Configuring the checker
- Packaging it as a Debian package
- Deploying and integrating it with ServiceRadar

## Prerequisites

- Go 1.18+ installed (see [Installation Guide](./installation.md) for build setup)
- Basic understanding of gRPC and ServiceRadar's architecture (see [Architecture](./architecture.md))
- Access to a ServiceRadar deployment with an Agent running
- Root or sudo privileges for deployment

## Step 1: Understand the Checker Architecture

ServiceRadar uses a plugin-based system for checkers, managed through the checker.Registry. The core interfaces are defined in pkg/checker/interfaces.go:

```go
// Checker defines how to check a service's status.
type Checker interface {
    Check(ctx context.Context) (bool, string)
}

// StatusProvider allows plugins to provide detailed status data.
type StatusProvider interface {
    GetStatusData() json.RawMessage
}

// HealthChecker combines basic checking with detailed status.
type HealthChecker interface {
    Checker
    StatusProvider
}
```

- `Check(ctx context.Context) (bool, string)`: Returns the service's availability (true/false) and a status message.
- `GetStatusData() json.RawMessage`: (Optional) Returns detailed status data as JSON.

The checker.Registry allows dynamic registration of checker factories, which are called by the Agent based on the service_type in the Poller's configuration (e.g., `/etc/serviceradar/poller.json`).

## Step 2: Write a Custom Checker

Let's create a simple checker to monitor a hypothetical "Weather Service" API, which returns weather data via HTTP. The checker will verify the API's availability and provide status details.

### Directory Structure

```
serviceradar/
├── cmd/
│   └── checkers/
│       └── weather/
│           └── main.go
├── pkg/
│   └── checker/
│       └── weather/
│           └── weather.go
└── proto/
    └── (existing protobuf files)
```

### 1. Define the Checker Logic (pkg/checker/weather/weather.go)

```go
package weather

import (
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "time"

    "github.com/carverauto/serviceradar/pkg/checker"
)

// Config holds the weather checker configuration.
type Config struct {
    Endpoint string        `json:"endpoint"`
    Timeout  time.Duration `json:"timeout"`
}

// WeatherChecker implements the HealthChecker interface.
type WeatherChecker struct {
    config Config
}

// NewWeatherChecker creates a new WeatherChecker instance.
func NewWeatherChecker(config Config) *WeatherChecker {
    return &WeatherChecker{config: config}
}

// Check verifies the weather service availability.
func (w *WeatherChecker) Check(ctx context.Context) (bool, string) {
    client := &http.Client{Timeout: w.config.Timeout}
    req, err := http.NewRequestWithContext(ctx, "GET", w.config.Endpoint, nil)
    if err != nil {
        return false, fmt.Sprintf("Failed to create request: %v", err)
    }

    resp, err := client.Do(req)
    if err != nil {
        return false, fmt.Sprintf("Weather service unavailable: %v", err)
    }
    defer resp.Body.Close()

    if resp.StatusCode != http.StatusOK {
        return false, fmt.Sprintf("Weather service returned status: %d", resp.StatusCode)
    }

    return true, "Weather service is operational"
}

// GetStatusData provides detailed weather status as JSON.
func (w *WeatherChecker) GetStatusData() json.RawMessage {
    // Mock data for this example
    data := map[string]interface{}{
        "status":      "healthy",
        "last_checked": time.Now().Format(time.RFC3339),
    }
    jsonData, _ := json.Marshal(data)
    return jsonData
}

// Factory creates a new WeatherChecker instance for the registry.
func Factory(ctx context.Context, serviceName, details string) (checker.Checker, error) {
    var config Config
    if err := json.Unmarshal([]byte(details), &config); err != nil {
        return nil, fmt.Errorf("Failed to parse config: %v", err)
    }
    if config.Endpoint == "" {
        config.Endpoint = "https://api.weather.example.com" // Default endpoint
    }
    if config.Timeout == 0 {
        config.Timeout = 10 * time.Second // Default timeout
    }
    return NewWeatherChecker(config), nil
}
```

### 2. Create the Main Program (cmd/checkers/weather/main.go)

```go
package main

import (
	"context"
	"flag"
	"fmt"
	"log"

	"github.com/carverauto/serviceradar/pkg/checker/weather"
	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/proto"
	"google.golang.org/grpc"
)

var (
	errFailedToLoadConfig = fmt.Errorf("failed to load config")
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("Fatal error: %v", err)
	}
}

func run() error {
	log.Printf("Starting Weather checker...")

	// Parse command line flags
	configPath := flag.String("config", "/etc/serviceradar/checkers/weather.json", "Path to config file")
	flag.Parse()

	// Setup a context we can use for loading the config and running the server
	ctx := context.Background()

	// Initialize configuration loader
	cfgLoader := config.NewConfig()

	// Load configuration with context
	var cfg weather.Config

	if err := cfgLoader.LoadAndValidate(ctx, *configPath, &cfg); err != nil {
		return fmt.Errorf("%w: %w", errFailedToLoadConfig, err)
	}

	// Create the checker
	checker := &weather.WeatherChecker{
		Config: cfg,
		Done:   make(chan struct{}),
	}

	// Create health server and API service
	weatherService := weather.NewWeatherService(checker)

	// Create gRPC service registrar
	registerServices := func(s *grpc.Server) error {
		proto.RegisterAgentServiceServer(s, weatherService)
		return nil
	}

	// Create and configure service options
	opts := lifecycle.ServerOptions{
		ListenAddr:           cfg.ListenAddr,
		Service:              &weatherService{checker: checker},
		RegisterGRPCServices: []lifecycle.GRPCServiceRegistrar{registerServices},
		EnableHealthCheck:    true,
		Security:             cfg.Security,
	}

	// Run service with lifecycle management
	if err := lifecycle.RunServer(ctx, &opts); err != nil {
		return fmt.Errorf("server error: %w", err)
	}

	return nil
}

// weatherService wraps the WeatherChecker to implement lifecycle.Service.
type weatherService struct {
	checker *weather.WeatherChecker
}

func (s *weatherService) Start(ctx context.Context) error {
	log.Printf("Starting Weather service...")

	return s.checker.StartMonitoring(ctx)
}

func (s *weatherService) Stop(_ context.Context) error {
	log.Printf("Stopping Weather service...")
	close(s.checker.Done)

	return nil
}
```

#### Explanation

- **Checker Logic**: The WeatherChecker sends an HTTP request to the weather API and checks the response. It also provides status data as JSON.
- **gRPC Server**: The main.go sets up a gRPC server to expose the checker's health status, integrating with ServiceRadar's Agent.
- **Factory**: The Factory function allows the Agent to instantiate the checker dynamically based on the Poller's configuration.

## Step 3: Configure the Checker

Create a configuration file at `/etc/serviceradar/checkers/weather.json`:

```json
{
  "endpoint": "https://api.weather.example.com",
  "timeout": "10s",
  "listen_addr": ":50055",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "checker"
  }
}
```

Update the Poller configuration (`/etc/serviceradar/poller.json`) to include the new checker:

```json
{
  "agents": {
    "local-agent": {
      "address": "localhost:50051",
      "security": { "mode": "none" },
      "checks": [
        {
          "service_type": "weather",
          "service_name": "weather-api",
          "details": "{\"endpoint\": \"https://api.weather.example.com\", \"timeout\": \"10s\"}"
        }
      ]
    }
  },
  "core_address": "localhost:50052",
  "listen_addr": ":50053",
  "poll_interval": "30s",
  "poller_id": "my-poller",
  "service_name": "PollerService",
  "service_type": "grpc",
  "security": { "mode": "none" }
}
```

## Step 4: Package the Checker as a Debian Package

Use the existing packaging scripts (e.g., setup-deb-dusk-checker.sh) as a template.

### Packaging Script (scripts/setup-deb-weather-checker.sh)

```bash
#!/bin/bash
set -e

VERSION=${VERSION:-1.0.0}
echo "Building serviceradar-weather-checker version ${VERSION}"

echo "Setting up package structure..."
PKG_ROOT="serviceradar-weather-checker_${VERSION}"
mkdir -p "${PKG_ROOT}/DEBIAN"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/etc/serviceradar/checkers"
mkdir -p "${PKG_ROOT}/lib/systemd/system"

echo "Building Go binary..."
GOOS=linux GOARCH=amd64 go build -o "${PKG_ROOT}/usr/local/bin/weather-checker" ./cmd/checkers/weather

echo "Creating package files..."
cat > "${PKG_ROOT}/DEBIAN/control" << EOF
Package: serviceradar-weather-checker
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Depends: systemd
Maintainer: Your Name <your.email@example.com>
Description: ServiceRadar Weather API checker
 Provides monitoring capabilities for weather APIs.
Config: /etc/serviceradar/checkers/weather.json
EOF

cat > "${PKG_ROOT}/DEBIAN/conffiles" << EOF
/etc/serviceradar/checkers/weather.json
EOF

cat > "${PKG_ROOT}/lib/systemd/system/serviceradar-weather-checker.service" << EOF
[Unit]
Description=ServiceRadar Weather Checker
After=network.target

[Service]
Type=simple
User=serviceradar
ExecStart=/usr/local/bin/weather-checker -config /etc/serviceradar/checkers/weather.json
Restart=always
RestartSec=10
LimitNPROC=512
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > "${PKG_ROOT}/etc/serviceradar/checkers/weather.json" << EOF
{
  "endpoint": "https://api.weather.example.com",
  "timeout": "10s",
  "listen_addr": ":50055",
  "security": {
    "mode": "none",
    "cert_dir": "/etc/serviceradar/certs",
    "role": "checker"
  }
}
EOF

cat > "${PKG_ROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e
if ! id -u serviceradar >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin serviceradar
fi
chown -R serviceradar:serviceradar /etc/serviceradar
chmod 755 /usr/local/bin/weather-checker
systemctl daemon-reload
systemctl enable serviceradar-weather-checker
systemctl start serviceradar-weather-checker
exit 0
EOF

cat > "${PKG_ROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e
systemctl stop serviceradar-weather-checker || true
systemctl disable serviceradar-weather-checker || true
exit 0
EOF

chmod 755 "${PKG_ROOT}/DEBIAN/postinst" "${PKG_ROOT}/DEBIAN/prerm"

echo "Building Debian package..."
mkdir -p ./release-artifacts
dpkg-deb --root-owner-group --build "${PKG_ROOT}"
mv "${PKG_ROOT}.deb" "./release-artifacts/"
echo "Package built: release-artifacts/${PKG_ROOT}.deb"
```

Run the script:

```bash
chmod +x scripts/setup-deb-weather-checker.sh
./scripts/setup-deb-weather-checker.sh
```

## Step 5: Deploy and Integrate

### Install the Package:

```bash
sudo dpkg -i release-artifacts/serviceradar-weather-checker_1.0.0.deb
```

### Restart Services:

```bash
sudo systemctl restart serviceradar-agent
sudo systemctl restart serviceradar-poller
```

### Verify Operation:

Check the checker's status:

```bash
sudo systemctl status serviceradar-weather-checker
```

Use grpcurl to test the health endpoint:

```bash
grpcurl -plaintext localhost:50055 grpc.health.v1.Health/Check
```

### Secure with mTLS (Optional):

Update the security section in weather.json and generate certificates as described in [TLS Security](./tls-security.md).

## Troubleshooting

- **Service Won't Start**: Check logs with `journalctl -u serviceradar-weather-checker`.
- **Agent Can't Find Checker**: Ensure the service_type matches the registry key (weather) and the checker is running.
- **gRPC Errors**: Verify the port (`:50055`) is not in use and is open in your firewall.

## Next Steps

- Enhance your checker with additional metrics or status data.
- Explore integrating with the KV store for dynamic configuration (see [Configuration Basics](./configuration.md)).
- Contribute your checker to the ServiceRadar community!

For more details, refer to the [Architecture](./architecture.md) and [TLS Security](./tls-security.md) documentation.