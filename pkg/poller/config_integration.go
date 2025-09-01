package poller

import (
    "context"
    "github.com/carverauto/serviceradar/proto"
)

// cpMap stores per-agent ConfigPollers when configrpc is enabled.
var cpMap = make(map[string][]*ConfigPoller)

func initAgentConfigPollers(name string, cfg *AgentConfig, client proto.AgentServiceClient, p *Poller) {
    cpMap[name] = BuildConfigPollers(name, cfg, client, p)
}

func collectAgentConfigStatuses(ctx context.Context, name string) []*proto.ServiceStatus {
    list := cpMap[name]
    if len(list) == 0 {
        return nil
    }
    return ExecuteConfigPollers(ctx, list)
}
