package poller

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/carverauto/serviceradar/pkg/logger"
	"github.com/carverauto/serviceradar/proto"
)

func TestResolveSourceIPUsesPodIPEnv(t *testing.T) {
	t.Setenv("SERVICERADAR_SOURCE_IP", "")
	t.Setenv("POD_IP", "192.0.2.15")
	t.Setenv("HOST_IP", "")
	t.Setenv("NODE_IP", "")

	ip := resolveSourceIP("auto", logger.NewTestLogger())
	require.Equal(t, "192.0.2.15", ip)
}

func TestPollerSourceIPNormalizesConfigValue(t *testing.T) {
	p := &Poller{
		config: Config{
			PollerID:  "poller-1",
			Partition: "default",
			SourceIP:  "10.0.0.5",
		},
		logger: logger.NewTestLogger(),
	}

	ip := p.sourceIP()
	require.Equal(t, "10.0.0.5", ip)
	assert.Equal(t, "10.0.0.5", p.config.SourceIP)
	assert.Equal(t, "10.0.0.5", p.resolvedSourceIP)
}

func TestCreateChunkUsesResolvedSourceIP(t *testing.T) {
	p := &Poller{
		config: Config{
			PollerID:  "poller-2",
			Partition: "default",
			SourceIP:  "auto",
		},
		resolvedSourceIP: "203.0.113.5",
		logger:           logger.NewTestLogger(),
	}

	chunk := p.createChunk([]*proto.ServiceStatus{{AgentId: "agent-1"}}, chunkPlan{
		totalChunks:  1,
		maxChunkSize: 1,
		timestamp:    time.Now().Unix(),
	}, 0)

	require.Equal(t, "203.0.113.5", chunk.SourceIp)
}
