package edgeonboarding

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestFlowggerCollectorMayPublishNormalizedLogs(t *testing.T) {
	publish, subscribe := GenerateCollectorPermissions("edge01", "flowgger")

	require.ElementsMatch(t, []string{"edge01.logs.syslog.>", "edge01.logs.normalized.>"}, publish)
	require.Empty(t, subscribe)

	otherPublish, _ := GenerateCollectorPermissions("edge01", "trapd")
	require.NotContains(t, otherPublish, "edge01.logs.normalized.>")
}
