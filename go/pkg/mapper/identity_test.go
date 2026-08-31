package mapper

import (
	"errors"
	"strconv"
	"testing"

	"github.com/gosnmp/gosnmp"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

const (
	testConfidenceHigh         = "high"
	testEvidenceEndpointAttach = "endpoint-attachment"
	testPhysicalMAC            = "02:42:49:7d:cf:00"
	testRelationAttachedTo     = "ATTACHED_TO"
)

var (
	errTestInterfaceLabelQuery = errors.New("label query timed out")
	errTestSNMPV1BulkWalk      = errors.New("SNMPV1 does not support GETBULK")
)

func TestGenerateDeviceIDNormalizesMAC(t *testing.T) {
	id1 := GenerateDeviceID("AA:BB:CC:DD:EE:FF")
	id2 := GenerateDeviceID("aa-bb-cc-dd-ee-ff")

	if id1 != "mac-aabbccddeeff" {
		t.Fatalf("unexpected normalized ID: %q", id1)
	}

	if id1 != id2 {
		t.Fatalf("expected equivalent MAC encodings to match: %q vs %q", id1, id2)
	}
}

func TestGenerateDeviceIDFromIPPrefix(t *testing.T) {
	id := GenerateDeviceIDFromIP("192.168.1.10")
	if id != "ip-192.168.1.10" {
		t.Fatalf("unexpected IP fallback ID: %q", id)
	}
}

func TestGenerateDeviceIDRejectsEmptyAndZeroMAC(t *testing.T) {
	if got := GenerateDeviceID(""); got != "" {
		t.Fatalf("expected empty MAC to mint no ID, got %q", got)
	}

	if got := GenerateDeviceID("00:00:00:00:00:00"); got != "" {
		t.Fatalf("expected all-zero MAC to mint no ID, got %q", got)
	}
}

func TestSelectPrimaryMACSkipsVRRPInterfaces(t *testing.T) {
	tests := []struct {
		name       string
		candidates []interfaceMACCandidate
		want       string
	}{
		{
			name: "vrrp interface before physical interface",
			candidates: []interfaceMACCandidate{
				{ifIndex: 2, ifName: "vrrp10", ifDescr: "vrrp10", mac: "e2:44:ac:eb:e7:44"},
				{ifIndex: 125, ifName: "eth0", ifDescr: "eth0", mac: testPhysicalMAC},
			},
			want: testPhysicalMAC,
		},
		{
			name: "vrrp identified by description",
			candidates: []interfaceMACCandidate{
				{ifIndex: 2, ifDescr: "VRRP10", mac: "e2:44:ac:eb:e7:44"},
				{ifIndex: 125, ifName: "eth0", mac: testPhysicalMAC},
			},
			want: testPhysicalMAC,
		},
		{
			name: "locally administered physical interface remains valid",
			candidates: []interfaceMACCandidate{
				{ifIndex: 125, ifName: "eth0", ifDescr: "eth0", mac: testPhysicalMAC},
			},
			want: testPhysicalMAC,
		},
		{
			name: "only vrrp interface",
			candidates: []interfaceMACCandidate{
				{ifIndex: 2, ifName: "vrrp10", ifDescr: "vrrp10", mac: "e2:44:ac:eb:e7:44"},
			},
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := selectPrimaryMAC(tt.candidates); got != tt.want {
				t.Fatalf("selectPrimaryMAC() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestGetMACAddressSkipsVRRPInterfaceMAC(t *testing.T) {
	pdus := map[string]gosnmp.SnmpPDU{
		oidIfPhysAddress + ".1": {
			Name:  oidIfPhysAddress + ".1",
			Type:  gosnmp.OctetString,
			Value: []byte{0, 0, 0, 0, 0, 0},
		},
		oidIfDescr + ".1": {
			Name: oidIfDescr + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfName + ".1": {
			Name: oidIfName + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfDescr + ".2": {
			Name: oidIfDescr + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10"),
		},
		oidIfName + ".2": {
			Name: oidIfName + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10"),
		},
		oidIfDescr + ".125": {
			Name: oidIfDescr + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
		oidIfName + ".125": {
			Name: oidIfName + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
	}
	client := &fakeSNMPMACReader{
		version: gosnmp.Version2c,
		get: func(oids []string) (*gosnmp.SnmpPacket, error) {
			return packetForOIDs(oids, pdus), nil
		},
		walks: map[string][]gosnmp.SnmpPDU{
			oidIfDescr: {
				{Name: oidIfDescr + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10")},
				{Name: oidIfDescr + ".125", Type: gosnmp.OctetString, Value: []byte("eth0")},
			},
			oidIfName: {
				{Name: oidIfName + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10")},
				{Name: oidIfName + ".125", Type: gosnmp.OctetString, Value: []byte("eth0")},
			},
			oidIfPhysAddress: {
				{
					Name:  oidIfPhysAddress + ".2",
					Type:  gosnmp.OctetString,
					Value: []byte{0xe2, 0x44, 0xac, 0xeb, 0xe7, 0x44},
				},
				{
					Name:  oidIfPhysAddress + ".125",
					Type:  gosnmp.OctetString,
					Value: []byte{0x02, 0x42, 0x49, 0x7d, 0xcf, 0x00},
				},
			},
		},
	}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	if got := engine.getMACAddress(client, "10.99.0.21", "test-job"); got != testPhysicalMAC {
		t.Fatalf("getMACAddress() = %q, want CORE-1 physical interface MAC", got)
	}
}

func TestGetMACAddressSupportsSNMPv1IndexOneMACWithoutIfName(t *testing.T) {
	pdus := map[string]gosnmp.SnmpPDU{
		oidIfPhysAddress + ".1": {
			Name:  oidIfPhysAddress + ".1",
			Type:  gosnmp.OctetString,
			Value: []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
		},
		oidIfDescr + ".1": {
			Name: oidIfDescr + ".1", Type: gosnmp.OctetString, Value: []byte("ethernet0"),
		},
	}
	client := &fakeSNMPMACReader{
		version:     gosnmp.Version1,
		bulkWalkErr: errTestSNMPV1BulkWalk,
		get: func(oids []string) (*gosnmp.SnmpPacket, error) {
			for _, oid := range oids {
				if oid == oidIfName+".1" {
					return &gosnmp.SnmpPacket{Error: gosnmp.NoSuchName}, nil
				}
			}

			return packetForOIDs(oids, pdus), nil
		},
	}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	if got := engine.getMACAddress(client, "192.0.2.10", "test-v1"); got != "00:11:22:33:44:55" {
		t.Fatalf("getMACAddress() = %q, want SNMPv1 index-one MAC", got)
	}
}

func TestGetMACAddressUsesWalkForSNMPv1Fallback(t *testing.T) {
	pdus := map[string]gosnmp.SnmpPDU{
		oidIfPhysAddress + ".1": {
			Name:  oidIfPhysAddress + ".1",
			Type:  gosnmp.OctetString,
			Value: []byte{0, 0, 0, 0, 0, 0},
		},
		oidIfDescr + ".1": {
			Name: oidIfDescr + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfDescr + ".2": {
			Name: oidIfDescr + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10"),
		},
		oidIfDescr + ".125": {
			Name: oidIfDescr + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
	}
	client := &fakeSNMPMACReader{
		version:     gosnmp.Version1,
		bulkWalkErr: errTestSNMPV1BulkWalk,
		get: func(oids []string) (*gosnmp.SnmpPacket, error) {
			for _, oid := range oids {
				if len(oid) >= len(oidIfName) && oid[:len(oidIfName)] == oidIfName {
					return &gosnmp.SnmpPacket{Error: gosnmp.NoSuchName}, nil
				}
			}

			return packetForOIDs(oids, pdus), nil
		},
		walks: map[string][]gosnmp.SnmpPDU{
			oidIfPhysAddress: {
				{
					Name:  oidIfPhysAddress + ".2",
					Type:  gosnmp.OctetString,
					Value: []byte{0xe2, 0x44, 0xac, 0xeb, 0xe7, 0x44},
				},
				{
					Name:  oidIfPhysAddress + ".125",
					Type:  gosnmp.OctetString,
					Value: []byte{0x02, 0x42, 0x49, 0x7d, 0xcf, 0x00},
				},
			},
		},
	}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	if got := engine.getMACAddress(client, "10.99.0.21", "test-v1"); got != testPhysicalMAC {
		t.Fatalf("getMACAddress() = %q, want SNMPv1 physical interface MAC", got)
	}
}

func TestGetMACAddressStopsWalkingAfterFirstNonVRRPCandidate(t *testing.T) {
	pdus := map[string]gosnmp.SnmpPDU{
		oidIfPhysAddress + ".1": {
			Name:  oidIfPhysAddress + ".1",
			Type:  gosnmp.OctetString,
			Value: []byte{0, 0, 0, 0, 0, 0},
		},
		oidIfDescr + ".1": {
			Name: oidIfDescr + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfName + ".1": {
			Name: oidIfName + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfDescr + ".2": {
			Name: oidIfDescr + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10"),
		},
		oidIfName + ".2": {
			Name: oidIfName + ".2", Type: gosnmp.OctetString, Value: []byte("vrrp10"),
		},
		oidIfDescr + ".125": {
			Name: oidIfDescr + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
		oidIfName + ".125": {
			Name: oidIfName + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
		oidIfDescr + ".300": {
			Name: oidIfDescr + ".300", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
		oidIfName + ".300": {
			Name: oidIfName + ".300", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
	}
	physicalAddresses := []gosnmp.SnmpPDU{
		{
			Name:  oidIfPhysAddress + ".2",
			Type:  gosnmp.OctetString,
			Value: []byte{0xe2, 0x44, 0xac, 0xeb, 0xe7, 0x44},
		},
	}
	for ifIndex := 200; ifIndex < 298; ifIndex++ {
		physicalAddresses = append(physicalAddresses, gosnmp.SnmpPDU{
			Name:  oidIfPhysAddress + "." + strconv.Itoa(ifIndex),
			Type:  gosnmp.OctetString,
			Value: []byte{0, 0, 0, 0, 0, 0},
		})
	}
	physicalAddresses = append(physicalAddresses,
		gosnmp.SnmpPDU{
			Name:  oidIfPhysAddress + ".300",
			Type:  gosnmp.OctetString,
			Value: []byte{0x02, 0x42, 0x49, 0x7d, 0xcf, 0x00},
		},
		gosnmp.SnmpPDU{
			Name:  oidIfPhysAddress + ".301",
			Type:  gosnmp.OctetString,
			Value: []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55},
		},
	)
	client := &fakeSNMPMACReader{
		version: gosnmp.Version2c,
		get: func(oids []string) (*gosnmp.SnmpPacket, error) {
			return packetForOIDs(oids, pdus), nil
		},
		walks: map[string][]gosnmp.SnmpPDU{
			oidIfPhysAddress: physicalAddresses,
		},
	}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	if got := engine.getMACAddress(client, "10.99.0.21", "test-budget"); got != testPhysicalMAC {
		t.Fatalf("getMACAddress() = %q, want physical interface MAC", got)
	}
	if client.getCalls > 3 {
		t.Fatalf("getMACAddress() made %d GET calls, want at most 3", client.getCalls)
	}
	if client.walkPDUVisits != 100 {
		t.Fatalf("getMACAddress() visited %d table rows, want early stop after 100", client.walkPDUVisits)
	}
}

func TestGetMACAddressRejectsCandidateWhenLabelsFail(t *testing.T) {
	pdus := map[string]gosnmp.SnmpPDU{
		oidIfPhysAddress + ".1": {
			Name: oidIfPhysAddress + ".1", Type: gosnmp.OctetString, Value: []byte{0, 0, 0, 0, 0, 0},
		},
		oidIfDescr + ".1": {
			Name: oidIfDescr + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfName + ".1": {
			Name: oidIfName + ".1", Type: gosnmp.OctetString, Value: []byte("lo"),
		},
		oidIfDescr + ".125": {
			Name: oidIfDescr + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
		oidIfName + ".125": {
			Name: oidIfName + ".125", Type: gosnmp.OctetString, Value: []byte("eth0"),
		},
	}
	client := &fakeSNMPMACReader{
		version: gosnmp.Version2c,
		get: func(oids []string) (*gosnmp.SnmpPacket, error) {
			for _, oid := range oids {
				if oid == oidIfDescr+".2" || oid == oidIfName+".2" {
					return nil, errTestInterfaceLabelQuery
				}
			}

			return packetForOIDs(oids, pdus), nil
		},
		walks: map[string][]gosnmp.SnmpPDU{
			oidIfPhysAddress: {
				{
					Name:  oidIfPhysAddress + ".2",
					Type:  gosnmp.OctetString,
					Value: []byte{0xe2, 0x44, 0xac, 0xeb, 0xe7, 0x44},
				},
				{
					Name:  oidIfPhysAddress + ".125",
					Type:  gosnmp.OctetString,
					Value: []byte{0x02, 0x42, 0x49, 0x7d, 0xcf, 0x00},
				},
			},
		},
	}
	engine := &DiscoveryEngine{logger: logger.NewTestLogger()}

	if got := engine.getMACAddress(client, "10.99.0.21", "test-label-error"); got != testPhysicalMAC {
		t.Fatalf("getMACAddress() = %q, want candidate after failed label lookup", got)
	}
}

type fakeSNMPMACReader struct {
	version       gosnmp.SnmpVersion
	get           func([]string) (*gosnmp.SnmpPacket, error)
	walks         map[string][]gosnmp.SnmpPDU
	bulkWalkErr   error
	getCalls      int
	walkPDUVisits int
}

func (f *fakeSNMPMACReader) Get(oids []string) (*gosnmp.SnmpPacket, error) {
	f.getCalls++

	if f.get == nil {
		return &gosnmp.SnmpPacket{}, nil
	}

	return f.get(oids)
}

func (f *fakeSNMPMACReader) BulkWalk(rootOID string, walkFn gosnmp.WalkFunc) error {
	if f.bulkWalkErr != nil {
		return f.bulkWalkErr
	}

	return f.visitWalk(rootOID, walkFn)
}

func (f *fakeSNMPMACReader) Walk(rootOID string, walkFn gosnmp.WalkFunc) error {
	return f.visitWalk(rootOID, walkFn)
}

func (f *fakeSNMPMACReader) SNMPVersion() gosnmp.SnmpVersion {
	return f.version
}

func (f *fakeSNMPMACReader) visitWalk(rootOID string, walkFn gosnmp.WalkFunc) error {
	for _, pdu := range f.walks[rootOID] {
		f.walkPDUVisits++
		if err := walkFn(pdu); err != nil {
			return err
		}
	}

	return nil
}

func packetForOIDs(oids []string, pdus map[string]gosnmp.SnmpPDU) *gosnmp.SnmpPacket {
	packet := &gosnmp.SnmpPacket{}
	for _, oid := range oids {
		if pdu, ok := pdus[oid]; ok {
			packet.Variables = append(packet.Variables, pdu)
		}
	}

	return packet
}

func TestEnsureDeviceIDFallsBackToIP(t *testing.T) {
	engine := &DiscoveryEngine{}
	device := &DiscoveredDevice{IP: "10.99.0.11"}

	engine.ensureDeviceID(device)

	if device.DeviceID != "ip-10.99.0.11" {
		t.Fatalf("expected IP fallback DeviceID, got %q", device.DeviceID)
	}
}

func TestEnsureDeviceIDPrefersMACOverIP(t *testing.T) {
	engine := &DiscoveryEngine{}
	device := &DiscoveredDevice{IP: "10.99.0.11", MAC: "02:42:9d:88:70:00"}

	engine.ensureDeviceID(device)

	if device.DeviceID != "mac-02429d887000" {
		t.Fatalf("expected MAC DeviceID, got %q", device.DeviceID)
	}
}

func TestGenerateDeviceIDFallsBackToIPWhenMACMissing(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results:   &DiscoveryResults{},
		deviceMap: map[string]*DeviceInterfaceMap{},
	}
	device := &DiscoveredDevice{IP: "10.99.0.11"}

	engine.generateDeviceID(job, device, device.IP)

	if device.DeviceID != "ip-10.99.0.11" {
		t.Fatalf("expected IP fallback DeviceID, got %q", device.DeviceID)
	}
}

func TestIsDeviceMatchFallsBackToMAC(t *testing.T) {
	engine := &DiscoveryEngine{}

	existing := &DiscoveredDevice{MAC: "AA:BB:CC:DD:EE:FF"}
	incoming := &DiscoveredDevice{MAC: "aa-bb-cc-dd-ee-ff"}

	if !engine.isDeviceMatch(existing, incoming) {
		t.Fatalf("expected normalized MAC match to be treated as same device")
	}
}

func TestIsDeviceMatchDoesNotMatchOnIPOnly(t *testing.T) {
	engine := &DiscoveryEngine{}

	existing := &DiscoveredDevice{IP: "192.168.1.1", DeviceID: "ip-192.168.1.1"}
	incoming := &DiscoveredDevice{IP: "192.168.1.2", DeviceID: "ip-192.168.1.2"}

	if engine.isDeviceMatch(existing, incoming) {
		t.Fatalf("did not expect IP-only identity mismatch to merge")
	}
}

func TestGenerateDeviceIDPrefersExistingIdentityForSameIP(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{
					DeviceID: "mac-f492bf75c721",
					IP:       "152.117.116.178",
					MAC:      "f4:92:bf:75:c7:21",
					Metadata: map[string]string{},
				},
			},
		},
		deviceMap: map[string]*DeviceInterfaceMap{},
	}

	device := &DiscoveredDevice{
		IP:       "152.117.116.178",
		MAC:      "f6:92:bf:75:c7:21",
		DeviceID: "",
	}

	engine.generateDeviceID(job, device, device.IP)

	if device.DeviceID != "mac-f492bf75c721" {
		t.Fatalf("expected existing ID to be reused, got %q", device.DeviceID)
	}

	if device.MAC != "f6:92:bf:75:c7:21" {
		t.Fatalf("expected SNMP MAC to remain on device object for conflict handling, got %q", device.MAC)
	}
}

func TestGenerateDeviceIDDoesNotReuseIdentityForDistinctHardware(t *testing.T) {
	engine := &DiscoveryEngine{}
	job := &DiscoveryJob{
		Results: &DiscoveryResults{
			Devices: []*DiscoveredDevice{
				{
					DeviceID: "mac-00602f3cd90b",
					IP:       "192.168.6.167",
					MAC:      "00:60:2f:3c:d9:0b",
					Metadata: map[string]string{},
				},
			},
		},
		deviceMap: map[string]*DeviceInterfaceMap{},
	}

	device := &DiscoveredDevice{
		IP:       "192.168.6.167",
		MAC:      "bc:24:11:26:40:e7",
		DeviceID: "",
	}

	engine.generateDeviceID(job, device, device.IP)

	if device.DeviceID != "mac-bc24112640e7" {
		t.Fatalf("expected distinct hardware to keep its own MAC identity, got %q", device.DeviceID)
	}
}

func TestApplyTopologyEvidenceClassAssignsConfidenceTier(t *testing.T) {
	link := &TopologyLink{
		Protocol: "lldp",
		Metadata: map[string]string{},
	}

	applyTopologyEvidenceClass(link)

	if link.Metadata["evidence_class"] != evidenceClassDirectPhysical {
		t.Fatalf("expected direct evidence class, got %q", link.Metadata["evidence_class"])
	}

	if link.Metadata["confidence_tier"] != testConfidenceHigh {
		t.Fatalf("expected high confidence tier, got %q", link.Metadata["confidence_tier"])
	}
}

func TestApplyTopologyEvidenceClassPreservesEndpointAttachment(t *testing.T) {
	link := &TopologyLink{
		Protocol: "UniFi-API",
		Metadata: map[string]string{
			"evidence_class": testEvidenceEndpointAttach,
			"source":         "unifi-api-wireless-client",
		},
	}

	applyTopologyEvidenceClass(link)

	if link.Metadata["evidence_class"] != testEvidenceEndpointAttach {
		t.Fatalf("expected endpoint-attachment evidence class, got %q", link.Metadata["evidence_class"])
	}

	if link.Metadata["relation_family"] != testRelationAttachedTo {
		t.Fatalf("expected ATTACHED_TO relation family, got %q", link.Metadata["relation_family"])
	}

	if link.Metadata["confidence_tier"] != testConfidenceHigh {
		t.Fatalf("expected high confidence tier, got %q", link.Metadata["confidence_tier"])
	}
}
