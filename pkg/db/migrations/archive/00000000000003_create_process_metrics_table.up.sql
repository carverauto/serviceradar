-- Create process_metrics table for system process monitoring
CREATE STREAM IF NOT EXISTS process_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    pid               uint32,
    name              string,
    cpu_usage         float32,
    memory_usage      uint64,
    status            string,
    start_time        string,
    device_id         string,
    partition         string
);