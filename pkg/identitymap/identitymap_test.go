package identitymap

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/models"
)

const testMACAddress = "aa:bb:cc:dd:ee:ff"

func TestBuildKeys(t *testing.T) {
	mac := testMACAddress
	update := &models.DeviceUpdate{
		DeviceID:  "tenant-a:1.2.3.4",
		IP:        "1.2.3.4",
		Partition: "tenant-a",
		MAC:       &mac,
		Metadata: map[string]string{
			"armis_device_id":  "armis-123",
			"integration_type": "netbox",
			"integration_id":   "nb-42",
			"netbox_device_id": "123",
			"extra_unrelated":  "ignored",
		},
	}

	keys := BuildKeys(update)

	assert.ElementsMatch(t, []Key{
		{Kind: KindDeviceID, Value: "tenant-a:1.2.3.4"},
		{Kind: KindIP, Value: "1.2.3.4"},
		{Kind: KindPartitionIP, Value: "tenant-a:1.2.3.4"},
		{Kind: KindArmisID, Value: "armis-123"},
		{Kind: KindNetboxID, Value: "nb-42"},
		{Kind: KindNetboxID, Value: "123"},
		{Kind: KindMAC, Value: "AA:BB:CC:DD:EE:FF"},
	}, keys)
}

func TestBuildKeysNil(t *testing.T) {
	var update *models.DeviceUpdate
	assert.Nil(t, BuildKeys(update))
}

func TestBuildKeysIncludesIPWhenDistinct(t *testing.T) {
	mac := testMACAddress
	update := &models.DeviceUpdate{
		DeviceID:  "device-123",
		IP:        "10.0.0.5",
		Partition: "tenant-a",
		MAC:       &mac,
	}

	keys := BuildKeys(update)

	assert.Contains(t, keys, Key{Kind: KindIP, Value: "10.0.0.5"})
	assert.Contains(t, keys, Key{Kind: KindPartitionIP, Value: "tenant-a:10.0.0.5"})
}

func TestBuildKeysIncludesAliasMetadata(t *testing.T) {
	mac := testMACAddress
	update := &models.DeviceUpdate{
		DeviceID:  "tenant-a:host-device",
		IP:        "10.0.0.5",
		Partition: "tenant-a",
		MAC:       &mac,
		Metadata: map[string]string{
			"_alias_last_seen_service_id":           "serviceradar:agent:k8s-agent",
			"_alias_last_seen_ip":                   "10.0.0.5",
			"service_alias:serviceradar:poller:k8s": "2025-11-03T15:00:00Z",
			"ip_alias:10.0.0.8":                     "2025-11-03T15:00:00Z",
			"armis_device_id":                       "armis-123",
			"integration_type":                      "netbox",
			"integration_id":                        "nb-42",
			"netbox_device_id":                      "123",
		},
	}

	keys := BuildKeys(update)

	assert.Contains(t, keys, Key{Kind: KindDeviceID, Value: "serviceradar:agent:k8s-agent"})
	assert.Contains(t, keys, Key{Kind: KindDeviceID, Value: "serviceradar:poller:k8s"})
	assert.Contains(t, keys, Key{Kind: KindIP, Value: "10.0.0.8"})
	assert.Contains(t, keys, Key{Kind: KindPartitionIP, Value: "tenant-a:10.0.0.8"})
}

func TestBuildKeysFromRecord(t *testing.T) {
	mac := "aa:bb:cc:dd:ee:ff"
	update := &models.DeviceUpdate{
		DeviceID:  "tenant-a:device-42",
		IP:        "10.1.2.3",
		Partition: "tenant-a",
		MAC:       &mac,
		Metadata: map[string]string{
			"armis_device_id":  "armis-42",
			"integration_id":   "nb-42",
			"integration_type": "netbox",
			"netbox_device_id": "device-42",
		},
	}

	record := &Record{
		CanonicalDeviceID: update.DeviceID,
		Partition:         update.Partition,
		MetadataHash:      HashIdentityMetadata(update),
		Attributes: map[string]string{
			"ip":               update.IP,
			"mac":              "AA:BB:CC:DD:EE:FF",
			"armis_device_id":  update.Metadata["armis_device_id"],
			"integration_id":   update.Metadata["integration_id"],
			"integration_type": update.Metadata["integration_type"],
			"netbox_device_id": update.Metadata["netbox_device_id"],
		},
	}

	keysFromRecord := BuildKeysFromRecord(record)
	keysFromUpdate := BuildKeys(update)

	assert.ElementsMatch(t, keysFromUpdate, keysFromRecord)
}

func TestMarshalRoundtrip(t *testing.T) {
	rec := &Record{
		CanonicalDeviceID: "tenant-a:canonical",
		Partition:         "tenant-a",
		MetadataHash:      "abc123",
		UpdatedAt:         time.UnixMilli(1700000000000).UTC(),
		Attributes: map[string]string{
			"source": "registry",
		},
	}

	bytes, err := MarshalRecord(rec)
	require.NoError(t, err)

	decoded, err := UnmarshalRecord(bytes)
	require.NoError(t, err)
	assert.Equal(t, rec.CanonicalDeviceID, decoded.CanonicalDeviceID)
	assert.Equal(t, rec.Partition, decoded.Partition)
	assert.Equal(t, rec.MetadataHash, decoded.MetadataHash)
	assert.Equal(t, rec.Attributes, decoded.Attributes)
	assert.Equal(t, rec.UpdatedAt, decoded.UpdatedAt)
}

func TestMarshalRecordErrors(t *testing.T) {
	_, err := MarshalRecord(nil)
	require.Error(t, err)

	_, err = UnmarshalRecord(nil)
	require.Error(t, err)
}

func TestHashMetadataDeterministic(t *testing.T) {
	m1 := map[string]string{"b": "two", "a": "one"}
	m2 := map[string]string{"a": "one", "b": "two"}

	hash1 := HashMetadata(m1)
	hash2 := HashMetadata(m2)

	assert.Equal(t, hash1, hash2)
	assert.NotEmpty(t, hash1)
}

func TestKeyPath(t *testing.T) {
	key := Key{Kind: KindArmisID, Value: "armis-123"}
	assert.Equal(t, "device_canonical_map/armis-id/armis-123", key.KeyPath(""))
	assert.Equal(t, "custom/armis-id/armis-123", key.KeyPath("/custom/"))
}

func TestKeyPathSanitizesDisallowedCharacters(t *testing.T) {
	key := Key{Kind: KindMAC, Value: "AA:BB:CC:DD:EE:FF"}
	assert.Equal(t, "device_canonical_map/mac/AA=3ABB=3ACC=3ADD=3AEE=3AFF", key.KeyPath(""))

	ipv6 := Key{Kind: KindIP, Value: "fe80::1"}
	assert.Equal(t, "device_canonical_map/ip/fe80=3A=3A1", ipv6.KeyPath(""))
}

func TestKeyPathVariantsIncludesLegacy(t *testing.T) {
	key := Key{Kind: KindMAC, Value: "AA:BB:CC:DD:EE:FF"}
	variants := key.KeyPathVariants("")
	require.Len(t, variants, 2)
	assert.Equal(t, "device_canonical_map/mac/AA=3ABB=3ACC=3ADD=3AEE=3AFF", variants[0])
	assert.Equal(t, "device_canonical_map/mac/AA:BB:CC:DD:EE:FF", variants[1])

	keyDevice := Key{Kind: KindDeviceID, Value: "tenant-a:1.2.3.4"}
	variants = keyDevice.KeyPathVariants("")
	require.Len(t, variants, 2)
	assert.Equal(t, "device_canonical_map/device-id/tenant-a=3A1.2.3.4", variants[0])
	assert.Equal(t, "device_canonical_map/device-id/tenant-a:1.2.3.4", variants[1])
}

func TestSanitizeKeyPath(t *testing.T) {
	assert.Equal(t,
		"device_canonical_map/mac/AA=3ABB=3ACC=3ADD=3AEE=3AFF",
		SanitizeKeyPath("device_canonical_map/mac/AA:BB:CC:DD:EE:FF"),
	)

	assert.Equal(t,
		"device_canonical_map/device-id/tenant-a=3A1.2.3.4",
		SanitizeKeyPath(" /device_canonical_map//device-id//tenant-a:1.2.3.4 "),
	)

	assert.Empty(t, SanitizeKeyPath(""))
	assert.Empty(t, SanitizeKeyPath("///"))
}

func TestHashIdentityMetadataIgnoresNoise(t *testing.T) {
	host := "sensor01"
	mac := testMACAddress
	update := &models.DeviceUpdate{
		DeviceID:  "tenant-a:1.2.3.4",
		IP:        "1.2.3.4",
		Partition: "tenant-a",
		Hostname:  &host,
		MAC:       &mac,
		Source:    models.DiscoverySourceNetbox,
		Metadata: map[string]string{
			"armis_device_id":      "armis-123",
			"integration_id":       "nb-42",
			"integration_type":     "netbox",
			"netbox_device_id":     "123",
			"port_scan_payload":    "changed",
			"alt_ip:1.2.3.4":       "1",
			"random_noise":         "value",
			"armis_device_id_copy": "ignored",
		},
	}

	hash1 := HashIdentityMetadata(update)

	update.Metadata["port_scan_payload"] = "changed-again"
	update.Metadata["random_noise"] = "different"

	hash2 := HashIdentityMetadata(update)
	assert.Equal(t, hash1, hash2)
}

func TestHashIdentityMetadataChangesOnCanonicalFields(t *testing.T) {
	update := &models.DeviceUpdate{
		DeviceID: "device-1",
		Metadata: map[string]string{"armis_device_id": "armis-123"},
	}

	original := HashIdentityMetadata(update)
	require.NotEmpty(t, original)

	update.Metadata["armis_device_id"] = "armis-124"
	changed := HashIdentityMetadata(update)
	assert.NotEqual(t, original, changed)
}
