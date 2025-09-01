package api

import "testing"

func TestDefaultKVKeyForService_Mappings(t *testing.T) {
    agent := "agent-1"

    cases := []struct{
        service     string
        serviceType string
        want        string
    }{
        {service: "sweep", serviceType: "sweep", want: "agents/agent-1/checkers/sweep/sweep.json"},
        {service: "snmp", serviceType: "snmp", want: "agents/agent-1/checkers/snmp/snmp.json"},
        {service: "serviceradar-mapper", serviceType: "grpc", want: "agents/agent-1/checkers/mapper/mapper.json"},
        {service: "trapd", serviceType: "grpc", want: "agents/agent-1/checkers/trapd/trapd.json"},
        {service: "rperf-checker", serviceType: "grpc", want: "agents/agent-1/checkers/rperf/rperf.json"},
        {service: "sysmon", serviceType: "grpc", want: "agents/agent-1/checkers/sysmon/sysmon.json"},
    }

    for _, tc := range cases {
        got, ok := defaultKVKeyForService(tc.service, tc.serviceType, agent)
        if !ok {
            t.Fatalf("expected mapping for %s/%s", tc.service, tc.serviceType)
        }
        if got != tc.want {
            t.Fatalf("mapping mismatch for %s/%s: got %q want %q", tc.service, tc.serviceType, got, tc.want)
        }
    }
}

func TestDefaultKVKeyForService_MissingAgent(t *testing.T) {
    if _, ok := defaultKVKeyForService("snmp", "snmp", ""); ok {
        t.Fatalf("expected ok=false when agent_id missing")
    }
}

