package mapper

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/go/pkg/logger"
)

type recordingInterfacePublisher struct {
	interfaces []*DiscoveredInterface
}

func (*recordingInterfacePublisher) PublishDevice(_ context.Context, _ *DiscoveredDevice) error {
	return nil
}

func (r *recordingInterfacePublisher) PublishInterface(_ context.Context, iface *DiscoveredInterface) error {
	r.interfaces = append(r.interfaces, iface)
	return nil
}

func (*recordingInterfacePublisher) PublishTopologyLink(_ context.Context, _ *TopologyLink) error {
	return nil
}

func TestRecursivePollingModes(t *testing.T) {
	t.Parallel()

	assert.Equal(t,
		[]snmpPollingMode{snmpPollingModeEnrichment, snmpPollingModeTopology},
		recursivePollingModes(DiscoveryTypeFull),
	)
	assert.Equal(t,
		[]snmpPollingMode{snmpPollingModeTopology},
		recursivePollingModes(DiscoveryTypeTopology),
	)
	assert.Nil(t, recursivePollingModes(DiscoveryTypeBasic))
	assert.Nil(t, recursivePollingModes(DiscoveryTypeInterfaces))
}

func TestFinalizePublishesInterfacesAddedAfterIdentityReconcile(t *testing.T) {
	t.Parallel()

	publisher := &recordingInterfacePublisher{}
	engine := &DiscoveryEngine{
		publisher: publisher,
		logger:    logger.NewTestLogger(),
	}

	job := &DiscoveryJob{
		ID:  "job-recursive-enrichment",
		ctx: context.Background(),
		Status: &DiscoveryStatus{
			Status: DiscoveryStatusRunning,
		},
		Results: &DiscoveryResults{
			Interfaces: []*DiscoveredInterface{
				{
					DeviceID: "sr:tonka01",
					DeviceIP: "192.168.10.1",
					IfIndex:  1,
					IfName:   "ge-0/0/1",
				},
			},
		},
	}

	engine.reconcileIdentity(job)
	require.Empty(t, publisher.interfaces)

	engine.upsertInterface(job, &DiscoveredInterface{
		DeviceID: "sr:aruba",
		DeviceIP: "192.168.10.154",
		IfIndex:  23,
		IfName:   "1/1/23",
	})

	engine.finalizeJobStatus(job)

	require.Len(t, publisher.interfaces, 2)
	assert.Equal(t, DiscoveryStatusCompleted, job.Status.Status)
	assert.True(t, job.interfacesPublished)
	assert.Len(t, job.Results.Interfaces, 2)
	assert.Equal(t, "192.168.10.1", publisher.interfaces[0].DeviceIP)
	assert.Equal(t, "192.168.10.154", publisher.interfaces[1].DeviceIP)
}
