package main

import (
	"context"
	"log"

	"github.com/carverauto/serviceradar/pkg/config"
	dbeventwriter "github.com/carverauto/serviceradar/pkg/consumers/db-event-writer"
	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/lifecycle"
	"github.com/carverauto/serviceradar/pkg/models"
)

func main() {
	ctx := context.Background()
	cfgLoader := config.NewConfig()

	configPath := "/etc/serviceradar/consumers/db-event-writer.json"

	var cfg dbeventwriter.DBEventWriterConfig

	if err := cfgLoader.LoadAndValidate(ctx, configPath, &cfg); err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	if err := cfg.Validate(); err != nil {
		log.Fatalf("DB event writer config validation failed: %v", err)
	}

	dbSecurity := cfg.Security
	if cfg.DBSecurity != nil {
		dbSecurity = cfg.DBSecurity
	}

	dbConfig := &models.DBConfig{
		DBAddr:   cfg.Database.Addresses[0],
		DBName:   cfg.Database.Name,
		DBUser:   cfg.Database.Username,
		DBPass:   cfg.Database.Password,
		Database: cfg.Database,
		Security: dbSecurity,
	}

	dbService, err := db.New(ctx, dbConfig)
	if err != nil {
		log.Fatalf("Failed to initialize database service: %v", err)
	}

	svc, err := dbeventwriter.NewService(&cfg, dbService)
	if err != nil {
		log.Fatalf("Failed to initialize event writer service: %v", err)
	}

	opts := &lifecycle.ServerOptions{
		ListenAddr:        cfg.ListenAddr,
		ServiceName:       "db-event-writer",
		Service:           svc,
		EnableHealthCheck: true,
		Security:          cfg.Security,
	}

	if err := lifecycle.RunServer(ctx, opts); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
