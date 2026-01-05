package poller

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/carverauto/serviceradar/proto"
)

func TestCalculateChunkPlan(t *testing.T) {
	poller := &Poller{}

	const maxChunkSize = 3 * 1024 * 1024
	largePayload := strings.Repeat("a", maxChunkSize+128)

	statuses := []*proto.ServiceStatus{
		{
			ServiceName: "large",
			Message:     []byte(largePayload),
		},
		{
			ServiceName: "small",
			Message:     []byte("ok"),
		},
	}

	plan := poller.calculateChunkPlan(statuses)
	expectedLargeChunks := (len(statuses[0].Message) + maxChunkSize - 1) / maxChunkSize

	assert.Equal(t, maxChunkSize, plan.maxChunkSize)
	assert.Equal(t, expectedLargeChunks+1, plan.totalChunks)
}
