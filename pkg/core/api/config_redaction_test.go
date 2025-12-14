package api

import (
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestRedactConfigBytes_Mapper(t *testing.T) {
	input := []byte(`{
		"default_credentials": {"version":"v2c","community":"public"},
		"credentials": [{"targets":["10.0.0.0/24"],"community":"secret"}],
		"scheduled_jobs": [{"name":"job-a","credentials":{"community":"job-secret"},"seeds":["10.0.0.1"]}],
		"unifi_apis": [{"name":"Main","base_url":"https://u","api_key":"api-secret"}],
		"workers": 5
	}`)

	out := redactConfigBytes("mapper", input)

	var doc map[string]any
	require.NoError(t, json.Unmarshal(out, &doc))

	defaultCreds := doc["default_credentials"].(map[string]any)
	require.Equal(t, redactedConfigValuePlaceholder, defaultCreds["community"])

	creds := doc["credentials"].([]any)
	cred0 := creds[0].(map[string]any)
	require.Equal(t, redactedConfigValuePlaceholder, cred0["community"])

	jobs := doc["scheduled_jobs"].([]any)
	job0 := jobs[0].(map[string]any)
	jobCreds := job0["credentials"].(map[string]any)
	require.Equal(t, redactedConfigValuePlaceholder, jobCreds["community"])

	unifi := doc["unifi_apis"].([]any)
	unifi0 := unifi[0].(map[string]any)
	require.Equal(t, redactedConfigValuePlaceholder, unifi0["api_key"])

	require.Equal(t, float64(5), doc["workers"])
}

func TestRestoreRedactedConfigBytes_Mapper(t *testing.T) {
	previous := []byte(`{
		"default_credentials": {"version":"v2c","community":"public"},
		"credentials": [{"targets":["10.0.0.0/24"],"community":"secret"}],
		"scheduled_jobs": [{"name":"job-a","credentials":{"community":"job-secret"},"seeds":["10.0.0.1"]}],
		"unifi_apis": [{"name":"Main","base_url":"https://u","api_key":"api-secret"}],
		"workers": 5
	}`)

	incoming := []byte(`{
		"default_credentials": {"version":"v2c","community":"__SR_REDACTED__"},
		"credentials": [{"targets":["10.0.0.0/24"],"community":"__SR_REDACTED__"}],
		"scheduled_jobs": [{"name":"job-a","credentials":{"community":"__SR_REDACTED__"},"seeds":["10.0.0.2"]}],
		"unifi_apis": [{"name":"Main","base_url":"https://u","api_key":"__SR_REDACTED__"}],
		"workers": 7
	}`)

	out := restoreRedactedConfigBytes("mapper", previous, incoming)

	var doc map[string]any
	require.NoError(t, json.Unmarshal(out, &doc))

	defaultCreds := doc["default_credentials"].(map[string]any)
	require.Equal(t, "public", defaultCreds["community"])

	creds := doc["credentials"].([]any)
	cred0 := creds[0].(map[string]any)
	require.Equal(t, "secret", cred0["community"])

	jobs := doc["scheduled_jobs"].([]any)
	job0 := jobs[0].(map[string]any)
	jobCreds := job0["credentials"].(map[string]any)
	require.Equal(t, "job-secret", jobCreds["community"])
	require.Equal(t, []any{"10.0.0.2"}, job0["seeds"])

	unifi := doc["unifi_apis"].([]any)
	unifi0 := unifi[0].(map[string]any)
	require.Equal(t, "api-secret", unifi0["api_key"])

	require.Equal(t, float64(7), doc["workers"])
}

func TestRedactConfigBytes_SNMPChecker(t *testing.T) {
	input := []byte(`{
		"node_address": "agent:50051",
		"listen_addr": ":50054",
		"partition": "docker",
		"targets": [{
			"name": "router",
			"host": "192.168.2.1",
			"port": 161,
			"community": "secret",
			"version": "v2c",
			"interval": "60s",
			"retries": 2,
			"oids": [{"oid":".1.3.6.1.2.1.1.3.0","name":"sysUpTime","type":"gauge","scale":1.0}]
		}]
	}`)

	out := redactConfigBytes("snmp-checker", input)

	var doc map[string]any
	require.NoError(t, json.Unmarshal(out, &doc))
	targets := doc["targets"].([]any)
	t0 := targets[0].(map[string]any)
	require.Equal(t, redactedConfigValuePlaceholder, t0["community"])
}

func TestRestoreRedactedConfigBytes_SNMPChecker(t *testing.T) {
	previous := []byte(`{
		"node_address": "agent:50051",
		"listen_addr": ":50054",
		"partition": "docker",
		"targets": [{
			"name": "router",
			"host": "192.168.2.1",
			"port": 161,
			"community": "secret",
			"version": "v2c",
			"interval": "60s",
			"retries": 2,
			"oids": [{"oid":".1.3.6.1.2.1.1.3.0","name":"sysUpTime","type":"gauge","scale":1.0}]
		}]
	}`)

	incoming := []byte(`{
		"node_address": "agent:50051",
		"listen_addr": ":50054",
		"partition": "docker",
		"targets": [{
			"name": "router",
			"host": "192.168.2.1",
			"port": 161,
			"community": "__SR_REDACTED__",
			"version": "v2c",
			"interval": "60s",
			"retries": 2,
			"oids": [{"oid":".1.3.6.1.2.1.1.3.0","name":"sysUpTime","type":"gauge","scale":1.0}]
		}]
	}`)

	out := restoreRedactedConfigBytes("snmp-checker", previous, incoming)

	var doc map[string]any
	require.NoError(t, json.Unmarshal(out, &doc))
	targets := doc["targets"].([]any)
	t0 := targets[0].(map[string]any)
	require.Equal(t, "secret", t0["community"])
}
