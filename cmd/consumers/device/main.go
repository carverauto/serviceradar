package main

import (
	"context"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	"github.com/carverauto/serviceradar/pkg/consumers/devices"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	ctx := context.Background()
	cfgLoader := config.NewConfig()
	configPath := "/etc/serviceradar/devices.json"

	var devCfg devices.DeviceConsumerConfig

	if err := cfgLoader.LoadAndValidate(ctx, configPath, &devCfg); err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}
	if err := devCfg.Validate(); err != nil {
		log.Fatalf("Device consumer config validation failed: %v", err)
	}

	dbSecurity := devCfg.Security
	if devCfg.DBSecurity != nil {
		dbSecurity = devCfg.DBSecurity
	}

	dbConfig := &models.DBConfig{
		DBAddr:   devCfg.Database.Addresses[0],
		DBName:   devCfg.Database.Name,
		DBUser:   devCfg.Database.Username,
		DBPass:   devCfg.Database.Password,
		Database: devCfg.Database,
		Security: dbSecurity,
	}

	dbService, err := db.New(ctx, dbConfig)
	if err != nil {
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	svc, err := devices.NewService(&devCfg, dbService)
	if err != nil {
		log.Fatalf("Failed to initialize device consumer service: %v", err)
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        devCfg.ListenAddr,
		ServiceName:       "device-consumer",
		Service:           svc,
		EnableHealthCheck: true,
		Security:          devCfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
