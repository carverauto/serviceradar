package identitymap

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/carverauto/serviceradar/pkg/models"
	identitymappb "github.com/carverauto/serviceradar/proto/identitymap/v1"
	"google.golang.org/protobuf/proto"
)

// Kind exposes the identity enum used for canonical map lookups.
type Kind = identitymappb.IdentityKind

const (
    KindUnspecified Kind = identitymappb.IdentityKind_IDENTITY_KIND_UNSPECIFIED
    KindDeviceID    Kind = identitymappb.IdentityKind_IDENTITY_KIND_DEVICE_ID
    KindArmisID     Kind = identitymappb.IdentityKind_IDENTITY_KIND_ARMIS_ID
    KindNetboxID    Kind = identitymappb.IdentityKind_IDENTITY_KIND_NETBOX_ID
    KindMAC         Kind = identitymappb.IdentityKind_IDENTITY_KIND_MAC
    KindIP          Kind = identitymappb.IdentityKind_IDENTITY_KIND_IP
    KindPartitionIP Kind = identitymappb.IdentityKind_IDENTITY_KIND_PARTITION_IP
)

// DefaultNamespace is the root prefix used for canonical identity map entries.
const DefaultNamespace = "device_canonical_map"

// Key represents a lookup identity used to locate a canonical device ID.
type Key struct {
	Kind  Kind
	Value string
}

// Record captures the canonical device information persisted in the KV map.
type Record struct {
	CanonicalDeviceID string
	Partition         string
	MetadataHash      string
	UpdatedAt         time.Time
	Attributes        map[string]string
}

var macRe = regexp.MustCompile(`(?i)[0-9a-f]{2}(?::[0-9a-f]{2}){5}`)

// BuildKeys derives the identity keys that should point at the canonical device for the update.
func BuildKeys(update *models.DeviceUpdate) []Key {
	if update == nil {
		return nil
	}

	keys := make([]Key, 0, 8)
	seen := make(map[string]struct{})
	add := func(kind Kind, raw string) {
		val := strings.TrimSpace(raw)
		if val == "" {
			return
		}
		ref := fmt.Sprintf("%d|%s", kind, val)
		if _, ok := seen[ref]; ok {
			return
		}
		seen[ref] = struct{}{}
		keys = append(keys, Key{Kind: kind, Value: val})
	}

	add(KindDeviceID, update.DeviceID)
	add(KindIP, update.IP)

	if update.Partition != "" && update.IP != "" {
		add(KindPartitionIP, partitionIPValue(update.Partition, update.IP))
	}

	if update.Metadata != nil {
		if armis := update.Metadata["armis_device_id"]; armis != "" {
			add(KindArmisID, armis)
		}

		if typ := update.Metadata["integration_type"]; strings.EqualFold(typ, "netbox") {
			if id := update.Metadata["integration_id"]; id != "" {
				add(KindNetboxID, id)
			}
			if id := update.Metadata["netbox_device_id"]; id != "" {
				add(KindNetboxID, id)
			}
		}
	}

	if update.MAC != nil {
		for _, mac := range parseMACList(*update.MAC) {
			add(KindMAC, mac)
		}
	}

	return keys
}

func partitionIPValue(partition, ip string) string {
	partition = strings.TrimSpace(partition)
	ip = strings.TrimSpace(ip)
	if partition == "" {
		return ip
	}
	if ip == "" {
		return partition
	}
	return fmt.Sprintf("%s:%s", partition, ip)
}

func parseMACList(s string) []string {
	if s == "" {
		return nil
	}
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return nil
	}

	if macRe.MatchString(trimmed) && !strings.Contains(trimmed, ",") {
		return []string{strings.ToUpper(macRe.FindString(trimmed))}
	}

	matches := macRe.FindAllString(trimmed, -1)
	if len(matches) == 0 {
		return nil
	}

	out := make([]string, 0, len(matches))
	seen := make(map[string]struct{})
	for _, match := range matches {
		mac := strings.ToUpper(match)
		if _, ok := seen[mac]; ok {
			continue
		}
		seen[mac] = struct{}{}
		out = append(out, mac)
	}
	return out
}

// ToProto converts the record into the protobuf representation.
func (r *Record) ToProto() *identitymappb.CanonicalRecord {
	if r == nil {
		return nil
	}
	pb := &identitymappb.CanonicalRecord{
		CanonicalDeviceId: r.CanonicalDeviceID,
		Partition:         r.Partition,
		MetadataHash:      r.MetadataHash,
		Attributes:        make(map[string]string, len(r.Attributes)),
	}

	if !r.UpdatedAt.IsZero() {
		pb.UpdatedAtUnixMillis = r.UpdatedAt.UTC().UnixMilli()
	}

	for k, v := range r.Attributes {
		pb.Attributes[k] = v
	}

	return pb
}

// FromProtoRecord converts a protobuf representation into a Record struct.
func FromProtoRecord(pb *identitymappb.CanonicalRecord) *Record {
	if pb == nil {
		return nil
	}

	rec := &Record{
		CanonicalDeviceID: pb.GetCanonicalDeviceId(),
		Partition:         pb.GetPartition(),
		MetadataHash:      pb.GetMetadataHash(),
		Attributes:        make(map[string]string, len(pb.GetAttributes())),
	}

	if pb.GetUpdatedAtUnixMillis() != 0 {
		rec.UpdatedAt = time.UnixMilli(pb.GetUpdatedAtUnixMillis()).UTC()
	}

	for k, v := range pb.GetAttributes() {
		rec.Attributes[k] = v
	}

	return rec
}

// ToProto converts the identity key into its protobuf representation.
func (k Key) ToProto() *identitymappb.IdentityKey {
	return &identitymappb.IdentityKey{
		Kind:  identitymappb.IdentityKind(k.Kind),
		Value: k.Value,
	}
}

// FromProtoKey converts a protobuf key message to the internal Key.
func FromProtoKey(pb *identitymappb.IdentityKey) Key {
	if pb == nil {
		return Key{}
	}
	return Key{Kind: Kind(pb.GetKind()), Value: pb.GetValue()}
}

// MarshalRecord encodes the record into bytes suitable for KV persistence.
func MarshalRecord(record *Record) ([]byte, error) {
	if record == nil {
		return nil, errors.New("identitymap: record is nil")
	}
	return proto.Marshal(record.ToProto())
}

// UnmarshalRecord decodes bytes retrieved from KV into a Record.
func UnmarshalRecord(data []byte) (*Record, error) {
	if len(data) == 0 {
		return nil, errors.New("identitymap: empty payload")
	}
	pb := &identitymappb.CanonicalRecord{}
	if err := proto.Unmarshal(data, pb); err != nil {
		return nil, fmt.Errorf("identitymap: failed to unmarshal canonical record: %w", err)
	}
	return FromProtoRecord(pb), nil
}

// KeyPath builds the storage path for a key under the provided namespace.
func (k Key) KeyPath(namespace string) string {
	ns := strings.Trim(namespace, "/")
    if ns == "" {
        ns = DefaultNamespace
	}
	return fmt.Sprintf("%s/%s/%s", ns, kindSegment(k.Kind), k.Value)
}

func kindSegment(kind Kind) string {
	switch kind {
	case KindDeviceID:
		return "device-id"
	case KindArmisID:
		return "armis-id"
	case KindNetboxID:
		return "netbox-id"
	case KindMAC:
		return "mac"
	case KindIP:
		return "ip"
	case KindPartitionIP:
		return "partition-ip"
	default:
		return strings.ToLower(kind.String())
	}
}
