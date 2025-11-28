/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package registry

import (
	"context"
	"testing"
	"time"

	"github.com/carverauto/serviceradar/pkg/db"
	"github.com/carverauto/serviceradar/pkg/models"
	"go.uber.org/mock/gomock"
)

func TestCNPGIdentityResolverResolveCanonicalIPs(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	// Setup test data
	testDevices := []*models.UnifiedDevice{
		{
			DeviceID: testDeviceID1,
			IP:       "192.168.1.1",
			Hostname: &models.DiscoveredField[string]{Value: "host1"},
		},
		{
			DeviceID: "device-2",
			IP:       "192.168.1.2",
			Hostname: &models.DiscoveredField[string]{Value: "host2"},
		},
	}

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"192.168.1.1", "192.168.1.2"}, []string(nil)).
		Return(testDevices, nil)

	resolver := &cnpgIdentityResolver{
		db:    mockDB,
		cache: newIdentityResolverCache(5*time.Minute, 1000),
	}

	// Test resolution
	resolved, err := resolver.resolveCanonicalIPs(context.Background(), []string{"192.168.1.1", "192.168.1.2"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(resolved) != 2 {
		t.Fatalf("expected 2 resolved IPs, got %d", len(resolved))
	}

	if resolved["192.168.1.1"] != testDeviceID1 {
		t.Errorf("expected %s for 192.168.1.1, got %s", testDeviceID1, resolved["192.168.1.1"])
	}

	if resolved["192.168.1.2"] != "device-2" {
		t.Errorf("expected device-2 for 192.168.1.2, got %s", resolved["192.168.1.2"])
	}
}

func TestCNPGIdentityResolverUsesCache(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	testDevices := []*models.UnifiedDevice{
		{
			DeviceID: testDeviceID1,
			IP:       "192.168.1.1",
		},
	}

	// DB should only be called once - second call should use cache
	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"192.168.1.1"}, []string(nil)).
		Return(testDevices, nil).
		Times(1)

	resolver := &cnpgIdentityResolver{
		db:    mockDB,
		cache: newIdentityResolverCache(5*time.Minute, 1000),
	}

	// First call - populates cache
	resolved1, err := resolver.resolveCanonicalIPs(context.Background(), []string{"192.168.1.1"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolved1["192.168.1.1"] != testDeviceID1 {
		t.Errorf("expected %s, got %s", testDeviceID1, resolved1["192.168.1.1"])
	}

	// Second call - should use cache, DB not called
	resolved2, err := resolver.resolveCanonicalIPs(context.Background(), []string{"192.168.1.1"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolved2["192.168.1.1"] != testDeviceID1 {
		t.Errorf("expected %s from cache, got %s", testDeviceID1, resolved2["192.168.1.1"])
	}
}

func TestCNPGIdentityResolverHydrateCanonical(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	testDevices := []*models.UnifiedDevice{
		{
			DeviceID: "canonical-device-1",
			IP:       "192.168.1.1",
			Hostname: &models.DiscoveredField[string]{Value: "canonical-host"},
			MAC:      &models.DiscoveredField[string]{Value: "AA:BB:CC:DD:EE:FF"},
			Metadata: &models.DiscoveredField[map[string]string]{
				Value: map[string]string{
					"armis_device_id": "armis-123",
					"integration_id":  "netbox-456",
				},
			},
		},
	}

	mockDB.EXPECT().
		GetUnifiedDevicesByIPsOrIDs(gomock.Any(), []string{"192.168.1.1"}, []string{"update-device-1"}).
		Return(testDevices, nil)

	resolver := &cnpgIdentityResolver{
		db:    mockDB,
		cache: newIdentityResolverCache(5*time.Minute, 1000),
	}

	// Create test updates
	updates := []*models.DeviceUpdate{
		{
			DeviceID: "update-device-1",
			IP:       "192.168.1.1",
			Metadata: make(map[string]string),
		},
	}

	err := resolver.hydrateCanonical(context.Background(), updates)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify metadata was applied
	if updates[0].Metadata["canonical_device_id"] != "canonical-device-1" {
		t.Errorf("expected canonical_device_id to be set, got %s", updates[0].Metadata["canonical_device_id"])
	}

	if updates[0].Metadata["canonical_hostname"] != "canonical-host" {
		t.Errorf("expected canonical_hostname to be set, got %s", updates[0].Metadata["canonical_hostname"])
	}

	if updates[0].Metadata["armis_device_id"] != "armis-123" {
		t.Errorf("expected armis_device_id to be set, got %s", updates[0].Metadata["armis_device_id"])
	}
}

func TestIdentityResolverCacheExpiry(t *testing.T) {
	cache := newIdentityResolverCache(10*time.Millisecond, 1000)

	cache.setIPMapping("192.168.1.1", "device-1")

	// Should find in cache
	deviceID, ok := cache.getIPMapping("192.168.1.1")
	if !ok {
		t.Fatal("expected to find IP in cache")
	}
	if deviceID != "device-1" {
		t.Errorf("expected device-1, got %s", deviceID)
	}

	// Wait for expiry
	time.Sleep(15 * time.Millisecond)

	// Should not find in cache after expiry
	_, ok = cache.getIPMapping("192.168.1.1")
	if ok {
		t.Error("expected cache entry to be expired")
	}
}

func TestIdentityResolverCacheEviction(t *testing.T) {
	// Create cache with max size of 10, it evicts 10% (1) when full
	cache := newIdentityResolverCache(5*time.Minute, 10)

	// Add 10 entries to fill the cache
	for i := 0; i < 10; i++ {
		cache.setIPMapping("192.168.1."+string(rune('0'+i)), "device-"+string(rune('0'+i)))
	}

	// Adding 11th entry should trigger eviction of 1 entry (10% of 10)
	cache.setIPMapping("192.168.1.99", "device-99")

	// The new entry should exist
	_, ok := cache.getIPMapping("192.168.1.99")
	if !ok {
		t.Error("expected new entry to exist after eviction")
	}

	// Count remaining entries - should be maxSize (eviction happens, then insert)
	count := 0
	cache.mu.RLock()
	count = len(cache.ipToDeviceID)
	cache.mu.RUnlock()

	// After eviction of 1 entry and adding 1 new entry, should be exactly 10
	if count != 10 {
		t.Errorf("expected 10 entries after eviction and insert, got %d", count)
	}
}

func TestWithCNPGIdentityResolverOption(t *testing.T) {
	ctrl := gomock.NewController(t)
	defer ctrl.Finish()

	mockDB := db.NewMockService(ctrl)

	reg := NewDeviceRegistry(mockDB, nil, WithCNPGIdentityResolver(mockDB))

	if reg.cnpgIdentityResolver == nil {
		t.Error("expected cnpgIdentityResolver to be set")
	}

	if reg.cnpgIdentityResolver.db != mockDB {
		t.Error("expected cnpgIdentityResolver.db to be set to mockDB")
	}

	if reg.cnpgIdentityResolver.cache == nil {
		t.Error("expected cnpgIdentityResolver.cache to be initialized")
	}
}
