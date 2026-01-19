package db

import (
	"context"

	"github.com/carverauto/serviceradar/pkg/models"
)

// PublishDiscoveredInterface stores a single discovered interface in device inventory.
func (db *DB) PublishDiscoveredInterface(ctx context.Context, iface *models.DiscoveredInterface) error {
	if iface == nil {
		return nil
	}

	return db.cnpgUpsertNetworkInterfaces(ctx, []*models.DiscoveredInterface{iface})
}

// PublishBatchDiscoveredInterfaces stores multiple discovered interfaces in device inventory.
func (db *DB) PublishBatchDiscoveredInterfaces(ctx context.Context, interfaces []*models.DiscoveredInterface) error {
	return db.cnpgUpsertNetworkInterfaces(ctx, interfaces)
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
