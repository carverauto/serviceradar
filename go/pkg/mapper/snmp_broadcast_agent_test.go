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

package mapper

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gosnmp/gosnmp"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

// fakeSNMPAgent is a minimal SNMPv2c agent over loopback UDP. It answers Get,
// GetNext and GetBulk from a static MIB, so interface discovery exercises the
// real gosnmp client and the real BulkWalk paging instead of handing PDUs to
// the parsers directly.
type fakeSNMPAgent struct {
	conn *net.UDPConn
	oids []string
	mib  map[string]gosnmp.SnmpPDU
}

func compareOIDs(a, b string) int {
	as := strings.Split(strings.TrimPrefix(a, "."), ".")
	bs := strings.Split(strings.TrimPrefix(b, "."), ".")

	for i := 0; i < len(as) && i < len(bs); i++ {
		ai, _ := strconv.Atoi(as[i])
		bi, _ := strconv.Atoi(bs[i])

		if ai != bi {
			if ai < bi {
				return -1
			}

			return 1
		}
	}

	return len(as) - len(bs)
}

func startFakeSNMPAgent(t *testing.T, pdus []gosnmp.SnmpPDU) *fakeSNMPAgent {
	t.Helper()

	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	require.NoError(t, err)

	agent := &fakeSNMPAgent{conn: conn, mib: make(map[string]gosnmp.SnmpPDU, len(pdus))}
	for _, pdu := range pdus {
		agent.mib[pdu.Name] = pdu
		agent.oids = append(agent.oids, pdu.Name)
	}

	sort.Slice(agent.oids, func(i, j int) bool { return compareOIDs(agent.oids[i], agent.oids[j]) < 0 })

	go agent.serve()

	t.Cleanup(func() { _ = conn.Close() })

	return agent
}

func (a *fakeSNMPAgent) port() uint16 {
	return uint16(a.conn.LocalAddr().(*net.UDPAddr).Port) //nolint:gosec // loopback port
}

func (a *fakeSNMPAgent) next(oid string) gosnmp.SnmpPDU {
	idx := sort.Search(len(a.oids), func(i int) bool { return compareOIDs(a.oids[i], oid) > 0 })
	if idx >= len(a.oids) {
		return gosnmp.SnmpPDU{Name: oid, Type: gosnmp.EndOfMibView}
	}

	return a.mib[a.oids[idx]]
}

func (a *fakeSNMPAgent) serve() {
	decoder := &gosnmp.GoSNMP{Version: gosnmp.Version2c, Community: "public"}
	buf := make([]byte, 65535)

	for {
		n, addr, err := a.conn.ReadFromUDP(buf)
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}

			continue
		}

		req, err := decoder.SnmpDecodePacket(buf[:n])
		if err != nil {
			continue
		}

		var vars []gosnmp.SnmpPDU

		switch req.PDUType {
		case gosnmp.GetRequest:
			for _, v := range req.Variables {
				if pdu, ok := a.mib[v.Name]; ok {
					vars = append(vars, pdu)
				} else {
					vars = append(vars, gosnmp.SnmpPDU{Name: v.Name, Type: gosnmp.NoSuchObject})
				}
			}
		case gosnmp.GetNextRequest:
			for _, v := range req.Variables {
				vars = append(vars, a.next(v.Name))
			}
		case gosnmp.GetBulkRequest:
			cursor := ""
			if len(req.Variables) > 0 {
				cursor = req.Variables[0].Name
			}

			for i := uint32(0); i < req.MaxRepetitions; i++ {
				pdu := a.next(cursor)
				vars = append(vars, pdu)

				if pdu.Type == gosnmp.EndOfMibView {
					break
				}

				cursor = pdu.Name
			}
		default:
			continue
		}

		resp := &gosnmp.SnmpPacket{
			Version:   gosnmp.Version2c,
			Community: req.Community,
			PDUType:   gosnmp.GetResponse,
			RequestID: req.RequestID,
			Variables: vars,
		}

		out, err := resp.MarshalMsg()
		if err != nil {
			continue
		}

		_, _ = a.conn.WriteToUDP(out, addr)
	}
}

func ipAddrTableRow(ip, mask string, ifIndex int) []gosnmp.SnmpPDU {
	rows := []gosnmp.SnmpPDU{
		{Name: oidIPAdEntAddr + "." + ip, Type: gosnmp.IPAddress, Value: ip},
		{Name: oidIPAdEntIfIndex + "." + ip, Type: gosnmp.Integer, Value: ifIndex},
	}

	if mask != "" {
		rows = append(rows, gosnmp.SnmpPDU{Name: oidIPAdEntNetMask + "." + ip, Type: gosnmp.IPAddress, Value: mask})
	}

	return rows
}

func ifTableRow(ifIndex int, descr string) []gosnmp.SnmpPDU {
	idx := strconv.Itoa(ifIndex)

	return []gosnmp.SnmpPDU{
		{Name: oidIfTable + ".1." + idx, Type: gosnmp.Integer, Value: ifIndex},
		{Name: oidIfDescr + "." + idx, Type: gosnmp.OctetString, Value: []byte(descr)},
	}
}

func interfacesByIndex(interfaces []*DiscoveredInterface) map[int32]*DiscoveredInterface {
	out := make(map[int32]*DiscoveredInterface, len(interfaces))
	for _, iface := range interfaces {
		out[iface.IfIndex] = iface
	}

	return out
}

// Drives queryInterfaces against an SNMP agent over UDP. Expected values come
// from IPv4 addressing rules rather than from the mapper: RFC 919/922 directed
// broadcast (all host bits set) and limited broadcast 255.255.255.255 are not
// host addresses, while RFC 3021 /31 links, /32 host routes and a .255 host
// inside a wider prefix are.
func TestQueryInterfacesOverSNMPDropsBroadcastAddresses(t *testing.T) {
	var mib []gosnmp.SnmpPDU

	mib = append(mib, ifTableRow(2, "ether2")...)
	mib = append(mib, ifTableRow(3, "wan1")...)
	mib = append(mib, ifTableRow(4, "lo0")...)
	mib = append(mib, ifTableRow(5, "p2p1")...)
	mib = append(mib, ifTableRow(6, "vlan6")...)

	mib = append(mib, ipAddrTableRow("192.0.2.1", "255.255.255.0", 2)...)
	mib = append(mib, ipAddrTableRow("192.0.2.255", "255.255.255.0", 2)...)     // directed broadcast of /24
	mib = append(mib, ipAddrTableRow("255.255.255.255", "255.255.255.0", 2)...) // limited broadcast
	mib = append(mib, ipAddrTableRow("203.0.113.255", "255.255.0.0", 3)...)     // valid host in /16
	mib = append(mib, ipAddrTableRow("198.51.100.255", "255.255.255.255", 4)...)
	mib = append(mib, ipAddrTableRow("198.51.100.3", "255.255.255.254", 5)...) // /31 point-to-point
	mib = append(mib, ipAddrTableRow("198.51.100.65", "255.255.255.192", 6)...)
	mib = append(mib, ipAddrTableRow("198.51.100.127", "", 6)...) // no mask on the legacy table

	// ipAddressTable classifies the unmasked legacy row as broadcast(3).
	mib = append(mib,
		gosnmp.SnmpPDU{Name: oidIPAddressIfIndex + ".1.4.198.51.100.127", Type: gosnmp.Integer, Value: 6},
		gosnmp.SnmpPDU{Name: oidIPAddressType + ".1.4.198.51.100.127", Type: gosnmp.Integer, Value: 3},
		gosnmp.SnmpPDU{Name: oidIPAddressIfIndex + ".1.4.198.51.100.65", Type: gosnmp.Integer, Value: 6},
		gosnmp.SnmpPDU{Name: oidIPAddressType + ".1.4.198.51.100.65", Type: gosnmp.Integer, Value: 1},
	)

	agent := startFakeSNMPAgent(t, mib)

	client := &gosnmp.GoSNMP{
		Target:         "127.0.0.1",
		Port:           agent.port(),
		Community:      "public",
		Version:        gosnmp.Version2c,
		Timeout:        2 * time.Second,
		Retries:        1,
		MaxRepetitions: 4,
	}
	require.NoError(t, client.Connect())

	defer func() { _ = client.Conn.Close() }()

	engine := &DiscoveryEngine{config: &Config{Timeout: 2 * time.Second}, logger: logger.NewTestLogger()}
	job := &DiscoveryJob{
		ID:      "snmp-broadcast-job",
		Params:  &DiscoveryParams{Options: map[string]string{}},
		Results: &DiscoveryResults{},
	}

	interfaces, err := engine.queryInterfaces(job, client, "127.0.0.1", job.ID)
	require.NoError(t, err)

	byIndex := interfacesByIndex(interfaces)
	require.Len(t, byIndex, 5)

	for _, iface := range interfaces {
		for _, ip := range iface.IPAddresses {
			assert.NotContains(t, []string{"192.0.2.255", "255.255.255.255", "198.51.100.127"}, ip,
				"interface %d reported broadcast address %s", iface.IfIndex, ip)
		}
	}

	assert.Equal(t, []string{"192.0.2.1"}, byIndex[2].IPAddresses)
	assert.Equal(t, "192.0.2.1/24", byIndex[2].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"203.0.113.255"}, byIndex[3].IPAddresses)
	assert.Equal(t, "203.0.113.255/16", byIndex[3].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"198.51.100.255"}, byIndex[4].IPAddresses)
	assert.Equal(t, "198.51.100.255/32", byIndex[4].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"198.51.100.3"}, byIndex[5].IPAddresses)
	assert.Equal(t, "198.51.100.3/31", byIndex[5].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"198.51.100.65"}, byIndex[6].IPAddresses)
}

// Drives the RouterOS REST collection path end to end against a disposable
// HTTP server standing in for /rest.
func TestQueryMikroTikDevicesDropsBroadcastAddresses(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		switch r.URL.Path {
		case "/rest/system/identity":
			_ = json.NewEncoder(w).Encode(map[string]any{"name": "rtr01"})
		case "/rest/system/resource":
			_ = json.NewEncoder(w).Encode(map[string]any{"version": "7.0", "board-name": "CHR"})
		case "/rest/interface":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{".id": "*2", "name": "bridge1", "type": "bridge", "mac-address": "00:11:22:00:00:01"},
				{".id": "*3", "name": "wan1", "type": "ether", "mac-address": "00:11:22:00:00:02"},
				{".id": "*4", "name": "p2p1", "type": "ether", "mac-address": "00:11:22:00:00:03"},
			})
		case "/rest/ip/address":
			_ = json.NewEncoder(w).Encode([]map[string]any{
				{"interface": "bridge1", "address": "192.0.2.1/24"},
				{"interface": "bridge1", "address": "192.0.2.255/24"},
				{"interface": "bridge1", "address": "255.255.255.255/32"},
				{"interface": "wan1", "address": "203.0.113.255/16"},
				{"interface": "p2p1", "address": "198.51.100.3/31"},
			})
		case "/rest/interface/bridge/port", "/rest/interface/bridge/vlan", "/rest/ip/neighbor":
			_ = json.NewEncoder(w).Encode([]map[string]any{})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	engine := &DiscoveryEngine{
		config: &Config{
			Timeout: 10 * time.Second,
			MikroTikAPIs: []MikroTikAPIConfig{
				{BaseURL: server.URL + "/rest", Username: "admin", Password: "secret", Name: "rtr01"},
			},
		},
		logger: logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID:     "mikrotik-broadcast-job",
		Params: &DiscoveryParams{Options: map[string]string{"mikrotik_api_names": "rtr01"}},
	}

	_, interfaces, _, err := engine.queryMikroTikDevices(context.Background(), job)
	require.NoError(t, err)

	byName := make(map[string]*DiscoveredInterface, len(interfaces))
	for _, iface := range interfaces {
		byName[iface.IfName] = iface
	}

	require.Contains(t, byName, "bridge1")
	require.Contains(t, byName, "wan1")
	require.Contains(t, byName, "p2p1")

	assert.Equal(t, []string{"192.0.2.1"}, byName["bridge1"].IPAddresses)
	assert.Equal(t, "192.0.2.1/24", byName["bridge1"].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"203.0.113.255"}, byName["wan1"].IPAddresses)
	assert.Equal(t, "203.0.113.255/16", byName["wan1"].Metadata["ip_cidrs"])
	assert.Equal(t, []string{"198.51.100.3"}, byName["p2p1"].IPAddresses)
	assert.Equal(t, "198.51.100.3/31", byName["p2p1"].Metadata["ip_cidrs"])
}
