package models

import (
	"context"
	"time"

	"github.com/carverauto/serviceradar/pkg/scan"
)

//go:generate mockgen -destination=mock_agent.go -package=models github.com/carverauto/serviceradar/pkg/models KVStore

// KVStore defines the interface for key-value store operations.
type KVStore interface {
	Get(ctx context.Context, key string) (value []byte, found bool, err error)
	Put(ctx context.Context, key string, value []byte, ttl time.Duration) error
	Delete(ctx context.Context, key string) error
	Watch(ctx context.Context, key string) (<-chan []byte, error)
	Close() error
}

// ICMPChecker performs ICMP checks using a pre-configured scanner.
type ICMPChecker struct {
	Host    string
	scanner scan.Scanner
}
