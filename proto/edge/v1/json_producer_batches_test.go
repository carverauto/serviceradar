/*
 * Copyright 2026 Carver Automation Corporation.
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

package edgev1_test

import (
	"testing"

	edgev1 "github.com/carverauto/serviceradar/proto/edge/v1"
	"google.golang.org/protobuf/proto"
)

func assertProtoRoundTrip[M proto.Message](t *testing.T, orig M, empty func() M) {
	t.Helper()

	wire, err := proto.Marshal(orig)
	if err != nil {
		t.Fatalf("proto.Marshal(%T) failed: %v", orig, err)
	}
	if len(wire) == 0 {
		t.Fatalf("proto.Marshal(%T) produced empty wire bytes", orig)
	}

	got := empty()
	if err := proto.Unmarshal(wire, got); err != nil {
		t.Fatalf("proto.Unmarshal(%T) failed: %v", orig, err)
	}
	if !proto.Equal(orig, got) {
		t.Fatalf("round-trip mismatch for %T:\norig: %+v\ngot:  %+v", orig, orig, got)
	}
}

func TestMapperBatchProtosRoundTrip(t *testing.T) {
	t.Parallel()

	speedBps := uint64(10_000_000_000)
	mtu := int32(9000)

	device := &edgev1.MapperDeviceRecordV1{
		DeviceId:          "sr:00000000-0000-4000-8000-000000000101",
		Ip:                "192.0.2.10",
		Source:            "mapper",
		TimestampUnixNano: 1700000000123456789,
		IsAvailable:       true,
		Hostname:          "sw-core-01.example.com",
		Mac:               "00:53:00:00:00:10",
		AgentId:           "agent-edge-01",
		GatewayId:         "gw-edge-01",
		Partition:         "default",
		SnmpFingerprint: &edgev1.MapperSnmpFingerprintV1{
			System: &edgev1.MapperSnmpSystemFingerprintV1{
				SysName:      "sw-core-01.example.com",
				SysDescr:     "Synthetic Switch OS 1.0",
				SysObjectId:  ".1.3.6.1.4.1.55555.1.1",
				SysContact:   "netops@example.com",
				SysLocation:  "rack-a1",
				IpForwarding: 1,
			},
			Bridge: &edgev1.MapperSnmpBridgeFingerprintV1{
				BridgeBaseMac:          "00:53:00:00:00:10",
				BridgePortCount:        24,
				StpForwardingPortCount: 22,
			},
			Vlan: &edgev1.MapperSnmpVlanFingerprintV1{
				VlanIdsSeen: []int32{1, 100, 200},
				PvidDistribution: []*edgev1.MapperSnmpVlanPvidCountV1{
					{Pvid: 1, Count: 4},
					{Pvid: 100, Count: 20},
				},
				PortEvidence: []*edgev1.MapperSnmpVlanPortEvidenceV1{
					{
						VlanId:           100,
						EgressPortsHex:   "fffff0",
						UntaggedPortsHex: "ffff00",
					},
				},
			},
			InterfaceSummary: &edgev1.MapperSnmpInterfaceSummaryV1{
				InterfaceCount: 26,
				IfTypeCounts: []*edgev1.MapperSnmpIfTypeCountV1{
					{IfType: 6, Count: 24},
					{IfType: 53, Count: 2},
				},
				BridgeLikeNameCount:   2,
				WirelessLikeNameCount: 0,
			},
			ExtractionErrors: map[string]string{
				"lldp_rem_man_addr": "no_such_instance",
			},
		},
		SyncServiceId:     "00000000-0000-4000-8000-000000000901",
		IdentityMacKind:   "primary",
		SysDescr:          "Synthetic Switch OS 1.0",
		SnmpDescription:   "Synthetic Switch OS 1.0",
		SysObjectId:       ".1.3.6.1.4.1.55555.1.1",
		SysName:           "sw-core-01.example.com",
		SnmpName:          "sw-core-01.example.com",
		SysContact:        "netops@example.com",
		SysOwner:          "netops@example.com",
		SnmpOwner:         "netops@example.com",
		SysLocation:       "rack-a1",
		SnmpLocation:      "rack-a1",
		IpForwarding:      1,
		BridgeBaseMac:     "00:53:00:00:00:10",
		Uptime:            86400,
		FirstSeenUnixNano: 1699900000000000000,
		LastSeenUnixNano:  1700000000123456789,
		Metadata: map[string]string{
			"discovery_id": "job-mapper-01",
		},
	}

	iface := &edgev1.MapperInterfaceRecordV1{
		DeviceId:      "sr:00000000-0000-4000-8000-000000000101",
		DeviceIp:      "192.0.2.10",
		IfIndex:       1,
		IfName:        "xe-0/0/0",
		IfDescr:       "10G Uplink Port 0",
		IfAlias:       "to-sw-dist-01",
		IfSpeed:       10_000_000_000,
		SpeedBps:      &speedBps,
		IfPhysAddress: "00:53:00:00:00:11",
		IpAddresses:   []string{"192.0.2.10", "198.51.100.1"},
		IfAdminStatus: 1,
		IfOperStatus:  1,
		IfType:        6,
		Mtu:           &mtu,
		Duplex:        "full",
		Source:        "snmp",
		Metadata: map[string]string{
			"ip_cidrs":        "192.0.2.10/24,198.51.100.1/30",
			"controller_url":  "https://unifi.example.com",
			"controller_name": "unifi-example",
			"site_id":         "site-01",
			"site_name":       "example-site",
			"unifi_device_id": "unifi-dev-01",
		},
		AvailableMetrics: []*edgev1.MapperInterfaceMetricV1{
			{
				Name:           "ifInOctets",
				Oid:            ".1.3.6.1.2.1.2.2.1.10.1",
				DataType:       "counter",
				Supports_64Bit: true,
				Oid_64Bit:      ".1.3.6.1.2.1.31.1.1.1.6.1",
				Category:       "traffic",
				Unit:           "bytes",
			},
		},
		TimestampUnixNano: 1700000000123456789,
		AgentId:           "agent-edge-01",
		GatewayId:         "gw-edge-01",
		Partition:         "default",
	}

	link := &edgev1.MapperTopologyLinkRecordV1{
		Protocol:           "LLDP",
		LocalDeviceIp:      "192.0.2.10",
		LocalDeviceId:      "sr:00000000-0000-4000-8000-000000000101",
		LocalIfIndex:       1,
		LocalIfName:        "xe-0/0/0",
		NeighborDeviceId:   "sr:00000000-0000-4000-8000-000000000102",
		NeighborChassisId:  "00:53:00:00:00:20",
		NeighborPortId:     "xe-0/0/1",
		NeighborPortDescr:  "Uplink to Core",
		NeighborSystemName: "sw-dist-01.example.com",
		NeighborMgmtAddr:   "192.0.2.11",
		NeighborIdentity: &edgev1.MapperNeighborIdentityV1{
			ManagementIp: "192.0.2.11",
			DeviceId:     "sr:00000000-0000-4000-8000-000000000102",
			ChassisId:    "00:53:00:00:00:20",
			PortId:       "xe-0/0/1",
			PortDescr:    "Uplink to Core",
			SystemName:   "sw-dist-01.example.com",
		},
		Observation: &edgev1.MapperTopologyObservationV2{
			ContractVersion:  "mapper.topology_observation.v2",
			ObservationType:  "topology_link",
			SourceProtocol:   "lldp",
			SourceAdapter:    "lldp.v1",
			EvidenceClass:    "direct-physical",
			ConfidenceTier:   "high",
			ConfidenceScore:  95,
			ConfidenceReason: "lldp_chassis_and_port_match",
			ObservedAtUnix:   1700000000,
			DiscoveryId:      "job-mapper-01",
			SourceEndpoint: &edgev1.MapperTopologyEndpointV1{
				Uid:      "sr:00000000-0000-4000-8000-000000000101:1",
				DeviceId: "sr:00000000-0000-4000-8000-000000000101",
				Ip:       "192.0.2.10",
				Mac:      "00:53:00:00:00:11",
				PortId:   "xe-0/0/0",
				IfName:   "xe-0/0/0",
				IfIndex:  1,
				Hostname: "sw-core-01.example.com",
				Site:     "example-site",
				SysName:  "sw-core-01.example.com",
			},
			TargetEndpoint: &edgev1.MapperTopologyEndpointV1{
				Uid:      "sr:00000000-0000-4000-8000-000000000102:2",
				DeviceId: "sr:00000000-0000-4000-8000-000000000102",
				Ip:       "192.0.2.11",
				Mac:      "00:53:00:00:00:20",
				PortId:   "xe-0/0/1",
				IfName:   "xe-0/0/1",
				IfIndex:  2,
				Hostname: "sw-dist-01.example.com",
				Site:     "example-site",
				SysName:  "sw-dist-01.example.com",
			},
			RawAttributes: map[string]string{
				"lldp_rem_sys_cap_enabled": "bridge,router",
			},
			RelationFamily: "CONNECTS_TO",
		},
		ConfidenceTier:   "high",
		ConfidenceScore:  95,
		ConfidenceReason: "lldp_chassis_and_port_match",
		Metadata: map[string]string{
			"source": "snmp-lldp",
		},
		TimestampUnixNano: 1700000000123456789,
		AgentId:           "agent-edge-01",
		GatewayId:         "gw-edge-01",
		Partition:         "default",
	}

	assertProtoRoundTrip(t, &edgev1.MapperDeviceBatchV1{
		AgentId:   "agent-edge-01",
		GatewayId: "gw-edge-01",
		Partition: "default",
		Devices:   []*edgev1.MapperDeviceRecordV1{device},
	}, func() *edgev1.MapperDeviceBatchV1 { return &edgev1.MapperDeviceBatchV1{} })

	assertProtoRoundTrip(t, &edgev1.MapperInterfaceBatchV1{
		AgentId:    "agent-edge-01",
		GatewayId:  "gw-edge-01",
		Partition:  "default",
		Interfaces: []*edgev1.MapperInterfaceRecordV1{iface},
	}, func() *edgev1.MapperInterfaceBatchV1 { return &edgev1.MapperInterfaceBatchV1{} })

	assertProtoRoundTrip(t, &edgev1.MapperTopologyBatchV1{
		AgentId:   "agent-edge-01",
		GatewayId: "gw-edge-01",
		Partition: "default",
		Links:     []*edgev1.MapperTopologyLinkRecordV1{link},
	}, func() *edgev1.MapperTopologyBatchV1 { return &edgev1.MapperTopologyBatchV1{} })

	assertProtoRoundTrip(t, &edgev1.MapperResultsBatchV1{
		AgentId:       "agent-edge-01",
		GatewayId:     "gw-edge-01",
		Partition:     "default",
		Devices:       []*edgev1.MapperDeviceRecordV1{device},
		Interfaces:    []*edgev1.MapperInterfaceRecordV1{iface},
		TopologyLinks: []*edgev1.MapperTopologyLinkRecordV1{link},
	}, func() *edgev1.MapperResultsBatchV1 { return &edgev1.MapperResultsBatchV1{} })
}

func TestNetprobeDiscoveryBatchProtoRoundTrip(t *testing.T) {
	t.Parallel()

	batch := &edgev1.NetprobeDiscoveryBatchV1{
		AgentId:            "agent-edge-01",
		GatewayId:          "gw-edge-01",
		Partition:          "default",
		CollectorIp:        "192.0.2.5",
		BatchStartUnixNano: 1700000000000000000,
		BatchEndUnixNano:   1700000010000000000,
		DroppedSinceLast:   0,
		Records: []*edgev1.NetprobeDiscoveryRecordV1{
			{
				Ip:                      "198.51.100.25",
				AgentId:                 "agent-edge-01",
				GatewayId:               "gw-edge-01",
				Partition:               "default",
				Source:                  "passive-netprobe",
				DiscoverySource:         "passive-netprobe",
				CollectorIp:             "192.0.2.5",
				AliasLastSeenIp:         "198.51.100.25",
				AliasLastSeenAtUnixNano: 1700000005000000000,
				TimestampUnixNano:       1700000005000000000,
				Metadata: map[string]string{
					"ip_alias:198.51.100.25": "2023-11-14T22:13:25Z",
				},
				Observation: &edgev1.NetprobeDiscoveryRecordV1_Fingerprint{
					Fingerprint: &edgev1.NetprobeFingerprintObservationV1{
						Source:             "passive-netprobe",
						ProfileId:          "00000000-0000-4000-8000-000000000201",
						ProfileName:        "default-passive",
						InterfaceName:      "eth0",
						ObservedAtUnixNano: 1700000005000000000,
						Protocol:           "tcp",
						Tcp: &edgev1.NetprobeTcpFingerprintV1{
							Signature:     "4:64+0:0:1460:mss*20,7:mss,sok,ts,nop,ws:df,id+:0",
							OsFamily:      "Linux",
							OsName:        "Linux 6.x",
							Confidence:    0.95,
							Ttl:           64,
							WindowSize:    "29200",
							Mss:           1460,
							OptionsLayout: []string{"mss", "sok", "ts", "nop", "ws"},
							Quirks:        []string{"df", "id+"},
							IpVersion:     "4",
							WindowScale:   7,
							PayloadClass:  "0",
						},
						Tls: &edgev1.NetprobeTlsFingerprintV1{
							Ja4:         "t13d1516h2_8daaf6152771_b186095e22b6",
							Ja4S:        "t130200_1301_234ea6891587",
							SniRedacted: "redacted",
						},
						Http: &edgev1.NetprobeHttpFingerprintV1{
							UserAgent:      "ExampleClient/1.0",
							Server:         "ExampleServer/2.0",
							AcceptLanguage: "en-US",
						},
						LicenseClean: &edgev1.NetprobeLicenseCleanFingerprintV1{
							P0FSignature: "4:64+0:0:1460:mss*20,7:mss,sok,ts,nop,ws:df,id+:0",
							P0FMatch: &edgev1.NetprobeP0FMatchV1{
								Label:         "s:unix:Linux:6.x",
								Name:          "Linux",
								VersionFlavor: "6.x",
								OsFamily:      "Linux",
							},
							Ja4: "t13d1516h2_8daaf6152771_b186095e22b6",
							Ja4Match: &edgev1.NetprobeFingerprintMatchV1{
								Name:         "Go-http-client",
								VersionRange: "1.22",
								OsFamily:     "Linux",
							},
							Hassh:       "ec7378c1a92f5a8dde7e8b7a12345678",
							HasshServer: "b12d2871a1189eff20364cf587654321",
							HasshMatch: &edgev1.NetprobeFingerprintMatchV1{
								Name:         "OpenSSH",
								VersionRange: "9.x",
								OsFamily:     "Linux",
							},
							OsMatch: &edgev1.NetprobeOsMatchV1{
								Name:         "Linux",
								VersionRange: "6.x",
								OsFamily:     "Linux",
								Confidence:   0.98,
								Disagreements: []*edgev1.NetprobeFingerprintDisagreementV1{
									{
										Signal:         "ja4",
										Signature:      "t13d1516h2_8daaf6152771_b186095e22b6",
										ObservedFamily: "Generic",
										ObservedName:   "Go-http-client",
										VersionRange:   "1.22",
									},
								},
							},
							AgreementCount: 3,
							Muonfp: &edgev1.NetprobeMuonFpMatchV1{
								Signature: "64:29200:1460:7:1,4,8,3",
								Label:     "Linux 6.x",
							},
							RecogHttp: &edgev1.NetprobeRecogMatchV1{
								Product:  "nginx",
								Version:  "1.26.0",
								OsFamily: "Linux",
							},
							RecogSsh: &edgev1.NetprobeRecogMatchV1{
								Product:  "OpenSSH",
								Version:  "9.6",
								OsFamily: "Linux",
							},
							SatoriMatches: []*edgev1.NetprobeSatoriMatchV1{
								{
									Axis:        "tcp",
									Signature:   "29200:64:1:60:M1460,S,T,N,W7:.",
									Label:       "Linux 6.x",
									DeviceClass: "server",
									OsFamily:    "Linux",
								},
							},
							TcpObserved:   true,
							Ja4Observed:   true,
							HasshObserved: true,
							HttpObserved:  true,
							SshObserved:   true,
						},
					},
				},
			},
			{
				Ip:                "198.51.100.26",
				AgentId:           "agent-edge-01",
				GatewayId:         "gw-edge-01",
				Partition:         "default",
				Source:            "passive-netprobe",
				DiscoverySource:   "passive-netprobe",
				CollectorIp:       "192.0.2.5",
				TimestampUnixNano: 1700000006000000000,
				Observation: &edgev1.NetprobeDiscoveryRecordV1_Dpi{
					Dpi: &edgev1.NetprobeDpiObservationV1{
						Source:                 "passive-netprobe",
						ProfileId:              "00000000-0000-4000-8000-000000000202",
						ProfileName:            "default-dpi",
						InterfaceName:          "eth0",
						Protocol:               "tls",
						Count:                  42,
						Confidence:             0.99,
						ObservedAtUnixNano:     1700000001000000000,
						LastObservedAtUnixNano: 1700000006000000000,
						SourceIp:               "198.51.100.26",
						DestinationIp:          "192.0.2.20",
						SourcePort:             51234,
						DestinationPort:        443,
						TransportProtocol:      "tcp",
						DissectorId:            "tls_client_hello",
						SubjectIp:              "198.51.100.26",
					},
				},
			},
			{
				Ip:                "192.0.2.5",
				AgentId:           "agent-edge-01",
				GatewayId:         "gw-edge-01",
				Partition:         "default",
				Source:            "passive-netprobe",
				DiscoverySource:   "passive-netprobe",
				CollectorIp:       "192.0.2.5",
				TimestampUnixNano: 1700000007000000000,
				Observation: &edgev1.NetprobeDiscoveryRecordV1_ProcessSnapshot{
					ProcessSnapshot: &edgev1.NetprobeProcessSnapshotObservationV1{
						Schema:             "summary_v1",
						Fingerprint:        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
						ObservedAtUnixNano: 1700000007000000000,
						EntryCount:         1,
						ProcessCount:       1,
						PortCount:          1,
						ContainerCount:     1,
						Protocols:          []string{"tcp"},
						ProtocolPortCounts: map[string]uint32{"tcp": 1},
						Entries: []*edgev1.NetprobeProcessEntryV1{
							{
								LocalIp:           "192.0.2.5",
								LocalPort:         8443,
								TransportProtocol: "tcp",
								Pid:               1234,
								Tgid:              1234,
								Uid:               1000,
								Gid:               1000,
								Comm:              "example-daemon",
								RedactedCmdline:   []string{"/usr/bin/example-daemon", "--port=8443"},
								ContainerId:       "container-0001",
								WorkloadIdentity: &edgev1.NetprobeWorkloadIdentityV1{
									PodSandboxId:      "sandbox-0001",
									PodName:           "example-pod-01",
									PodNamespace:      "example-ns",
									PodUid:            "00000000-0000-4000-8000-000000000301",
									ContainerId:       "container-0001",
									ContainerName:     "example-daemon",
									Image:             "registry.example.com/example-daemon:1.0.0",
									ImageRef:          "registry.example.com/example-daemon@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
									RuntimePid:        1234,
									CgroupPath:        "/kubepods.slice/pod0001/container-0001",
									RuntimeSource:     "containerd",
									Confidence:        "high",
									DegradationReason: "",
									Labels: map[string]string{
										"app.kubernetes.io/name": "example-daemon",
									},
									Annotations: map[string]string{
										"example.com/team": "platform",
									},
								},
								ExecutableOwnership: &edgev1.NetprobeExecutableOwnershipV1{
									ResolutionState:  "resolved",
									Detail:           "dpkg-status",
									SourceScope:      "container",
									PackageType:      "deb",
									PackageManager:   "dpkg",
									Namespace:        "debian",
									Release:          "12",
									Ecosystem:        "Debian:12",
									BinaryPackage:    "example-daemon",
									SourcePackage:    "example-daemon",
									Architecture:     "amd64",
									InstalledVersion: "1.0.0-1",
									Resolver:         "dpkg_status",
									ExecutablePath:   "/usr/bin/example-daemon",
									ExecutableDev:    2049,
									ExecutableInode:  65536,
								},
							},
						},
					},
				},
			},
		},
	}

	assertProtoRoundTrip(t, batch, func() *edgev1.NetprobeDiscoveryBatchV1 {
		return &edgev1.NetprobeDiscoveryBatchV1{}
	})
}

func TestSyncPageBatchProtoRoundTrip(t *testing.T) {
	t.Parallel()

	osTypeID := int32(100)
	cpuBits := int32(64)
	cpuCores := int32(8)
	cpuCount := int32(1)
	cpuSpeedMhz := int32(3200)
	ramSize := int64(34359738368)
	riskLevelID := int32(1)
	riskScore := int32(15)
	isAvailable := true
	isManaged := true
	isCompliant := true
	isTrusted := true
	ifTypeID := int32(6)
	hiddenSSID := false
	vlan := int32(100)
	userTypeID := int32(1)
	agentTypeID := int32(4)

	syncMeta := &edgev1.SyncMetaV1{
		SyncServiceId: "00000000-0000-4000-8000-000000000401",
		SyncRunId:     "00000000-0000-4000-8000-000000000402",
		ChunkIndex:    0,
		TotalChunks:   2,
		TotalDevices:  2,
		IsFinal:       false,
		Population: &edgev1.SyncPopulationReportV1{
			RawRows:                      10,
			ExcludedRows:                 1,
			InvalidRows:                  1,
			ValidOccurrences:             8,
			DistinctSourceIds:            7,
			DuplicateOccurrences:         1,
			ConflictingDuplicateIds:      1,
			DuplicateSourceIdExamples:    []string{"1001"},
			InvalidRowExamples:           []string{"query=example page=0 row=4"},
			ConflictingDuplicateExamples: []string{"1001"},
		},
	}

	pageBatch := &edgev1.SyncPageBatchV1{
		SyncMeta: syncMeta,
		Devices: []*edgev1.SyncDeviceRecordV1{
			{
				DeviceId:         "sr:00000000-0000-4000-8000-000000000501",
				Uid:              "sr:00000000-0000-4000-8000-000000000501",
				UidAlt:           "armis:1001",
				AgentId:          "agent-edge-01",
				GatewayId:        "gw-edge-01",
				Partition:        "default",
				Ip:               "192.0.2.50",
				Mac:              "00:53:00:00:00:50",
				Hostname:         "host-50.example.com",
				Name:             "host-50",
				Source:           "armis",
				SourceInstance:   "https://armis.example.com",
				DiscoverySources: []string{"armis", "netbox"},
				Type:             "Server",
				TypeId:           1,
				DeviceType:       "virtual_machine",
				VendorName:       "ExampleCorp",
				Model:            "ExampleServer X1",
				Domain:           "example.com",
				Zone:             "dmz",
				SubnetUid:        "subnet-192-0-2-0",
				VlanUid:          "vlan-100",
				Region:           "us-example-1",
				Os: &edgev1.SyncDeviceOsV1{
					Name:          "Debian GNU/Linux",
					Type:          "Linux",
					TypeId:        &osTypeID,
					Version:       "12",
					Build:         "bookworm",
					Edition:       "server",
					KernelRelease: "6.1.0-example",
					CpuBits:       &cpuBits,
					SpName:        "none",
					SpVer:         "0",
					Lang:          "en_US",
				},
				OsInfo:      "Debian GNU/Linux 12",
				VersionInfo: "6.1.0-example",
				HwInfo: &edgev1.SyncDeviceHwInfoV1{
					CpuArchitecture:  "x86_64",
					CpuBits:          &cpuBits,
					CpuCores:         &cpuCores,
					CpuCount:         &cpuCount,
					CpuSpeedMhz:      &cpuSpeedMhz,
					CpuType:          "Synthetic CPU 3.2GHz",
					RamSize:          &ramSize,
					SerialNumber:     "SN-EXAMPLE-000501",
					Chassis:          "rackmount",
					BiosManufacturer: "ExampleBIOS",
					BiosVer:          "1.2.3",
					BiosDate:         "2026-01-01",
					Uuid:             "00000000-0000-4000-8000-000000000599",
				},
				RiskLevelId:           &riskLevelID,
				RiskLevel:             "Low",
				RiskScore:             &riskScore,
				IsAvailable:           &isAvailable,
				IsManaged:             &isManaged,
				IsCompliant:           &isCompliant,
				IsTrusted:             &isTrusted,
				ServiceType:           "host",
				ServiceStatus:         "online",
				LastHeartbeatUnixNano: 1700000000000000000,
				TimestampUnixNano:     1700000000000000000,
				FirstSeenUnixNano:     1699000000000000000,
				LastSeenUnixNano:      1700000000000000000,
				CreatedTimeUnixNano:   1699000000000000000,
				ModifiedTimeUnixNano:  1700000000000000000,
				NetworkInterfaces: []*edgev1.SyncNetworkInterfaceV1{
					{
						Name:                "eth0",
						Description:         "Primary NIC",
						Alias:               "mgmt0",
						MacAddress:          "00:53:00:00:00:50",
						Ipv4Address:         "192.0.2.50",
						Ipv6Address:         "2001:db8::50",
						IpAddresses:         []string{"192.0.2.50", "2001:db8::50"},
						Cidr:                "192.0.2.0/24",
						Subnet:              "192.0.2.0/24",
						Hostname:            "host-50.example.com",
						Uid:                 "nic-01",
						Type:                "wired",
						TypeId:              &ifTypeID,
						Brand:               "ExampleNIC",
						BroadcastSsid:       "example-corp-wifi",
						HiddenBroadcastSsid: &hiddenSSID,
						LastConnectedSsid:   "example-corp-wifi",
						Channels:            []string{"36", "40"},
						Vlan:                &vlan,
						Metadata: map[string]string{
							"port_mode": "access",
						},
					},
				},
				Owner: &edgev1.SyncDeviceUserV1{
					Uid:    "user-01",
					Name:   "Example Operator",
					Email:  "operator@example.com",
					Type:   "admin",
					TypeId: &userTypeID,
				},
				Org: &edgev1.SyncDeviceOrganizationV1{
					Uid:    "org-01",
					Name:   "Example Organization",
					OuUid:  "ou-01",
					OuName: "Infrastructure",
				},
				Groups: []*edgev1.SyncDeviceGroupV1{
					{
						Uid:  "grp-01",
						Name: "Core Servers",
						Type: "static",
						Desc: "Synthetic server group",
					},
				},
				AgentList: []*edgev1.SyncDeviceAgentV1{
					{
						Uid:        "edr-01",
						Name:       "ExampleAgent",
						Type:       "edr",
						TypeId:     &agentTypeID,
						Version:    "4.5.6",
						VendorName: "ExampleSecurity",
					},
				},
				SwitchPortAttachment: map[string]string{
					"switch_name": "sw-core-01.example.com",
					"port_name":   "xe-0/0/5",
				},
				Metadata: map[string]string{
					"armis_device_id":  "1001",
					"integration_id":   "00000000-0000-4000-8000-000000000401",
					"integration_type": "armis",
					"sync_service_id":  "00000000-0000-4000-8000-000000000401",
					"boundaries":       "default-boundary",
					"source_tags":      "core",
					"mac_addresses":    "00-00-5E-00-53-01",
					"ipv4_addresses":   "192.0.2.10",
					"os_name":          "ExampleOS",
					"risk_score":       "15",
				},
				Tags: map[string]string{
					"env": "test",
				},
				Facts: map[string]string{
					"virtualization": "kvm",
				},
				SyncMeta: syncMeta,
			},
		},
	}

	assertProtoRoundTrip(t, pageBatch, func() *edgev1.SyncPageBatchV1 {
		return &edgev1.SyncPageBatchV1{}
	})

	finalControlBatch := &edgev1.SyncPageBatchV1{
		SyncMeta: &edgev1.SyncMetaV1{
			SyncServiceId: "00000000-0000-4000-8000-000000000401",
			SyncRunId:     "00000000-0000-4000-8000-000000000402",
			ChunkIndex:    1,
			TotalChunks:   2,
			TotalDevices:  2,
			IsFinal:       true,
			Population:    syncMeta.GetPopulation(),
		},
		ControlMarker: &edgev1.SyncControlMarkerV1{
			ControlType:       "collection_final",
			TimestampUnixNano: 1700000010000000000,
		},
	}

	assertProtoRoundTrip(t, finalControlBatch, func() *edgev1.SyncPageBatchV1 {
		return &edgev1.SyncPageBatchV1{}
	})
}
