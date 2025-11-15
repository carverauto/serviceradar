package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// PublishDiscoveredInterface stores a single discovered interface in CNPG.
func (db *DB) PublishDiscoveredInterface(ctx context.Context, iface *models.DiscoveredInterface) error {
	if iface == nil {
		return nil
	}

	return db.cnpgInsertDiscoveredInterfaces(ctx, []*models.DiscoveredInterface{iface})
}

// PublishBatchDiscoveredInterfaces stores multiple discovered interfaces.
func (db *DB) PublishBatchDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error {
	return db.cnpgInsertDiscoveredInterfaces(ctx, interfaces)
}

// PublishTopologyDiscoveryEvent stores a single topology discovery event.
func (db *DB) PublishTopologyDiscoveryEvent(ctx context.Context, event *models.TopologyDiscoveryEvent) error {
	if event == nil {
		return nil
	}

	return db.cnpgInsertTopologyEvents(ctx, []*models.TopologyDiscoveryEvent{event})
}

// PublishBatchTopologyDiscoveryEvents stores multiple topology events in CNPG.
func (db *DB) PublishBatchTopologyDiscoveryEvents(ctx context.Context, events []*models.TopologyDiscoveryEvent) error {
	return db.cnpgInsertTopologyEvents(ctx, events)
}
