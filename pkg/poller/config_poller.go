package poller

import (
    "context"
    "time"

    "github.com/carverauto/serviceradar/proto"
)

// ConfigPoller manages GetConfig polling for services that support it.
type ConfigPoller struct {
    client      proto.AgentServiceClient
    check       Check
    pollerID    string
    agentName   string
    lastConfig  time.Time
    interval    time.Duration
    poller      *Poller // parent poller
}

// executeGetConfig retrieves configuration for a service and wraps it for core.
func (cp *ConfigPoller) executeGetConfig(ctx context.Context) *proto.ServiceStatus {
    req := &proto.ConfigRequest{
        ServiceName: cp.check.Name,
        ServiceType: cp.check.Type,
        AgentId:     cp.agentName,
        PollerId:    cp.pollerID,
    }

    // Prefer streaming for large configs in future; for now, unary call
    resp, err := cp.client.GetConfig(ctx, req)
    if err != nil || resp == nil {
        // On error, return a minimal status to record attempt
        return &proto.ServiceStatus{
            ServiceName: cp.check.Name,
            ServiceType: cp.check.Type,
            Available:   false,
            Message:     []byte(`{"error":"getconfig failed"}`),
            AgentId:     cp.agentName,
            PollerId:    cp.pollerID,
            Source:      "config",
        }
    }

    // Wrap config into ServiceStatus for core ingestion (Source = config)
    kvID := resp.KvStoreId
    // Fallback to poller KVAddress if service didn't return an ID
    if kvID == "" && cp.poller != nil {
        kvID = cp.poller.config.KVAddress
    }

    return &proto.ServiceStatus{
        ServiceName:  cp.check.Name,
        ServiceType:  cp.check.Type,
        Available:    true,
        Message:      resp.Config,
        AgentId:      resp.AgentId,
        PollerId:     cp.pollerID,
        Source:       "config",
        KvStoreId:    kvID,
        ResponseTime: 0,
    }
}

// BuildConfigPollers constructs ConfigPollers from agent config checks with config_interval.
func BuildConfigPollers(name string, config *AgentConfig, client proto.AgentServiceClient, p *Poller) []*ConfigPoller {
    list := make([]*ConfigPoller, 0)
    if config == nil {
        return list
    }
    for _, check := range config.Checks {
        if check.ConfigInterval == nil {
            continue
        }
        cp := &ConfigPoller{
            client:    client,
            check:     check,
            pollerID:  p.config.PollerID,
            agentName: name,
            interval:  time.Duration(*check.ConfigInterval),
            poller:    p,
        }
        list = append(list, cp)
    }
    return list
}

// ExecuteConfigPollers runs GetConfig for all given config pollers as needed.
func ExecuteConfigPollers(ctx context.Context, pollers []*ConfigPoller) []*proto.ServiceStatus {
    now := time.Now()
    out := make([]*proto.ServiceStatus, 0, len(pollers))
    for _, cp := range pollers {
        if cp == nil {
            continue
        }
        if now.Sub(cp.lastConfig) < cp.interval {
            continue
        }
        if status := cp.executeGetConfig(ctx); status != nil {
            out = append(out, status)
        }
        cp.lastConfig = now
    }
    return out
}
