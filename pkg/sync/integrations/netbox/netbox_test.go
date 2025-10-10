package netbox

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"

	"github.com/carverauto/serviceradar/pkg/identitymap"
	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/pkg/models"
	"github.com/carverauto/serviceradar/proto"
)

func TestProcessDevices_UsesIDs(t *testing.T) {
	integ := &NetboxIntegration{
		Config: &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "test-partition"},
		Logger: logger.NewTestLogger(),
	}

	resp := DeviceResponse{Results: []Device{
		{
			ID:   1,
			Name: "host1",
			Role: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "role"},
			Site: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "site"},
			PrimaryIP4: struct {
				ID      int    "json:\"id\""
				Address string "json:\"address\""
			}{ID: 1, Address: "10.0.0.1/32"},
		},
	}}

	data, ips, events := integ.processDevices(context.Background(), resp)
	require.Len(t, ips, 1)
	require.Equal(t, "10.0.0.1/32", ips[0])
	require.Empty(t, data, "netbox sync should omit per-device KV payloads")

	require.Len(t, events, 1)
	require.Equal(t, "10.0.0.1", events[0].IP)
	require.Equal(t, "poller", events[0].PollerID)
	require.Equal(t, models.DiscoverySourceNetbox, events[0].Source)
	require.Equal(t, "test-partition", events[0].Partition)
}

type fakeKVClient struct {
	getFn      func(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error)
	batchGetFn func(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error)
}

func (f *fakeKVClient) Get(ctx context.Context, in *proto.GetRequest, opts ...grpc.CallOption) (*proto.GetResponse, error) {
	if f.getFn != nil {
		return f.getFn(ctx, in, opts...)
	}
	return &proto.GetResponse{}, nil
}

func (f *fakeKVClient) BatchGet(ctx context.Context, in *proto.BatchGetRequest, opts ...grpc.CallOption) (*proto.BatchGetResponse, error) {
	if f.batchGetFn != nil {
		return f.batchGetFn(ctx, in, opts...)
	}

	resp := &proto.BatchGetResponse{Results: make([]*proto.BatchGetEntry, 0, len(in.GetKeys()))}
	for _, key := range in.GetKeys() {
		single, err := f.Get(ctx, &proto.GetRequest{Key: key}, opts...)
		if err != nil {
			return nil, err
		}
		resp.Results = append(resp.Results, &proto.BatchGetEntry{
			Key:      key,
			Value:    single.GetValue(),
			Found:    single.GetFound(),
			Revision: single.GetRevision(),
		})
	}

	return resp, nil
}

func (*fakeKVClient) Put(context.Context, *proto.PutRequest, ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (*fakeKVClient) PutIfAbsent(context.Context, *proto.PutRequest, ...grpc.CallOption) (*proto.PutResponse, error) {
	return &proto.PutResponse{}, nil
}

func (*fakeKVClient) PutMany(context.Context, *proto.PutManyRequest, ...grpc.CallOption) (*proto.PutManyResponse, error) {
	return &proto.PutManyResponse{}, nil
}

func (*fakeKVClient) Update(context.Context, *proto.UpdateRequest, ...grpc.CallOption) (*proto.UpdateResponse, error) {
	return &proto.UpdateResponse{}, nil
}

func (*fakeKVClient) Delete(context.Context, *proto.DeleteRequest, ...grpc.CallOption) (*proto.DeleteResponse, error) {
	return &proto.DeleteResponse{}, nil
}

func (*fakeKVClient) Watch(context.Context, *proto.WatchRequest, ...grpc.CallOption) (proto.KVService_WatchClient, error) {
	return nil, nil
}

func (*fakeKVClient) Info(context.Context, *proto.InfoRequest, ...grpc.CallOption) (*proto.InfoResponse, error) {
	return &proto.InfoResponse{}, nil
}

func TestProcessDevices_DoesNotHydrateCanonicalMetadata(t *testing.T) {
	canonical := &identitymap.Record{CanonicalDeviceID: "canonical-42", Partition: "prod", MetadataHash: "hash"}
	payload, err := identitymap.MarshalRecord(canonical)
	require.NoError(t, err)

	fake := &fakeKVClient{
		getFn: func(ctx context.Context, req *proto.GetRequest, _ ...grpc.CallOption) (*proto.GetResponse, error) {
			if strings.Contains(req.Key, "/netbox-id/1") {
				return &proto.GetResponse{Value: payload, Found: true, Revision: 7}, nil
			}
			return &proto.GetResponse{Found: false}, nil
		},
	}

	integ := &NetboxIntegration{
		Config:   &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "test-partition"},
		KvClient: fake,
		Logger:   logger.NewTestLogger(),
	}

	resp := DeviceResponse{Results: []Device{
		{
			ID:   1,
			Name: "host1",
			Role: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "role"},
			Site: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "site"},
			PrimaryIP4: struct {
				ID      int    "json:\"id\""
				Address string "json:\"address\""
			}{ID: 1, Address: "10.0.0.1/32"},
		},
	}}

	data, _, events := integ.processDevices(context.Background(), resp)
	require.Len(t, events, 1)
	_, hasCanonical := events[0].Metadata["canonical_device_id"]
	require.False(t, hasCanonical, "sync should not hydrate canonical metadata")
	require.Empty(t, data)
}

func TestProcessDevices_SkipsCanonicalPrefetch(t *testing.T) {
	fake := &fakeKVClient{}
	var captured [][]string
	fake.batchGetFn = func(ctx context.Context, req *proto.BatchGetRequest, _ ...grpc.CallOption) (*proto.BatchGetResponse, error) {
		keys := append([]string(nil), req.GetKeys()...)
		captured = append(captured, keys)
		resp := &proto.BatchGetResponse{Results: make([]*proto.BatchGetEntry, len(keys))}
		for i, key := range keys {
			resp.Results[i] = &proto.BatchGetEntry{Key: key, Found: false}
		}
		return resp, nil
	}

	integ := &NetboxIntegration{
		Config:   &models.SourceConfig{AgentID: "agent", PollerID: "poller", Partition: "part"},
		KvClient: fake,
		Logger:   logger.NewTestLogger(),
	}

	resp := DeviceResponse{Results: []Device{
		{
			ID:   1,
			Name: "host1",
			Role: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "role"},
			Site: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 1, Name: "site"},
			PrimaryIP4: struct {
				ID      int    "json:\"id\""
				Address string "json:\"address\""
			}{ID: 1, Address: "10.0.0.1/32"},
		},
		{
			ID:   2,
			Name: "host2",
			Role: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 2, Name: "role"},
			Site: struct {
				ID   int    "json:\"id\""
				Name string "json:\"name\""
			}{ID: 2, Name: "site"},
			PrimaryIP4: struct {
				ID      int    "json:\"id\""
				Address string "json:\"address\""
			}{ID: 2, Address: "10.0.0.2/32"},
		},
	}}

	_, _, events := integ.processDevices(context.Background(), resp)
	require.Len(t, events, 2)
	require.Empty(t, captured, "sync should not issue KV BatchGet calls")
}

func TestParseTCPPorts(t *testing.T) {
	tests := []struct {
		name          string
		credentials   map[string]string
		expectedPorts []int
		description   string
	}{
		{
			name:          "default ports when tcp_ports not set",
			credentials:   map[string]string{},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when tcp_ports credential is not set",
		},
		{
			name:          "default ports when tcp_ports is empty",
			credentials:   map[string]string{"tcp_ports": ""},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when tcp_ports credential is empty",
		},
		{
			name:          "custom single port",
			credentials:   map[string]string{"tcp_ports": "9090"},
			expectedPorts: []int{9090},
			description:   "should parse single custom port",
		},
		{
			name:          "custom multiple ports",
			credentials:   map[string]string{"tcp_ports": "22,80,443,9090"},
			expectedPorts: []int{22, 80, 443, 9090},
			description:   "should parse multiple custom ports",
		},
		{
			name:          "custom ports with spaces",
			credentials:   map[string]string{"tcp_ports": "22, 80, 443 , 9090"},
			expectedPorts: []int{22, 80, 443, 9090},
			description:   "should parse custom ports with spaces",
		},
		{
			name:          "invalid ports mixed with valid",
			credentials:   map[string]string{"tcp_ports": "22,invalid,443,99999"},
			expectedPorts: []int{22, 443},
			description:   "should parse only valid ports and skip invalid ones",
		},
		{
			name:          "all invalid ports",
			credentials:   map[string]string{"tcp_ports": "invalid,99999,-1"},
			expectedPorts: []int{22, 80, 443, 3389, 445, 5985, 5986, 8080},
			description:   "should return default NetBox ports when all provided ports are invalid",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			config := &models.SourceConfig{
				Credentials: tt.credentials,
			}

			result := parseTCPPorts(config)
			require.Equal(t, tt.expectedPorts, result, tt.description)
		})
	}
}
