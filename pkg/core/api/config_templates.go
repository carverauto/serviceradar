package api

import (
	_ "embed"

	"github.com/carverauto/serviceradar/pkg/config"
)

// templateAsset stores an embedded default configuration and its format.
type templateAsset struct {
	data   []byte
	format config.ConfigFormat
}

var (
	//go:embed templates/core.json
	templateCore []byte
	//go:embed templates/sync.json
	templateSync []byte
	//go:embed templates/poller.json
	templatePoller []byte
	//go:embed templates/agent.json
	templateAgent []byte
	//go:embed templates/db-event-writer.json
	templateDBEventWriter []byte
	//go:embed templates/datasvc.json
	templateDatasvc []byte
	//go:embed templates/mapper.json
	templateMapper []byte
	//go:embed templates/faker.json
	templateFaker []byte
	//go:embed templates/trapd.json
	templateTrapd []byte
	//go:embed templates/zen-consumer.json
	templateZenConsumer []byte
	//go:embed templates/flowgger.toml
	templateFlowgger []byte
	//go:embed templates/otel.toml
	templateOTEL []byte
	//go:embed templates/snmp-checker.json
	templateSNMPChecker []byte
	//go:embed templates/dusk-checker.json
	templateDuskChecker []byte
	//go:embed templates/sysmon-vm-checker.json
	templateSysmonChecker []byte
	//go:embed templates/netflow-consumer.json
	templateNetflowConsumer []byte
	//go:embed templates/agent-sweep.json
	templateAgentSweep []byte
	//go:embed templates/agent-snmp.json
	templateAgentSNMP []byte
	//go:embed templates/agent-mapper.json
	templateAgentMapper []byte
	//go:embed templates/agent-trapd.json
	templateAgentTrapd []byte
	//go:embed templates/agent-rperf.json
	templateAgentRperf []byte
	//go:embed templates/agent-sysmon.json
	templateAgentSysmon []byte
)

//nolint:gochecknoglobals // Template registry must be package-level
var serviceTemplates = map[string]templateAsset{
	"core":              {data: templateCore, format: config.ConfigFormatJSON},
	"sync":              {data: templateSync, format: config.ConfigFormatJSON},
	"poller":            {data: templatePoller, format: config.ConfigFormatJSON},
	"agent":             {data: templateAgent, format: config.ConfigFormatJSON},
	"db-event-writer":   {data: templateDBEventWriter, format: config.ConfigFormatJSON},
	"datasvc":           {data: templateDatasvc, format: config.ConfigFormatJSON},
	"mapper":            {data: templateMapper, format: config.ConfigFormatJSON},
	"faker":             {data: templateFaker, format: config.ConfigFormatJSON},
	"trapd":             {data: templateTrapd, format: config.ConfigFormatJSON},
	"zen-consumer":      {data: templateZenConsumer, format: config.ConfigFormatJSON},
	"flowgger":          {data: templateFlowgger, format: config.ConfigFormatTOML},
	"otel":              {data: templateOTEL, format: config.ConfigFormatTOML},
	"snmp-checker":      {data: templateSNMPChecker, format: config.ConfigFormatJSON},
	"dusk-checker":      {data: templateDuskChecker, format: config.ConfigFormatJSON},
	"sysmon-vm-checker": {data: templateSysmonChecker, format: config.ConfigFormatJSON},
	"netflow-consumer":  {data: templateNetflowConsumer, format: config.ConfigFormatJSON},
	"agent-sweep":       {data: templateAgentSweep, format: config.ConfigFormatJSON},
	"agent-snmp":        {data: templateAgentSNMP, format: config.ConfigFormatJSON},
	"agent-mapper":      {data: templateAgentMapper, format: config.ConfigFormatJSON},
	"agent-trapd":       {data: templateAgentTrapd, format: config.ConfigFormatJSON},
	"agent-rperf":       {data: templateAgentRperf, format: config.ConfigFormatJSON},
	"agent-sysmon":      {data: templateAgentSysmon, format: config.ConfigFormatJSON},
}
