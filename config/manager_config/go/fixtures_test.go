package manager_test

import (
	configpb "github.com/carverauto/serviceradar/config/proto_bindings/go"
	"google.golang.org/protobuf/proto"
)

// A rule set built here rather than read from //config/rules:ruleset_binpb.
//
// These tests are about what the manager DOES with a rule set -- delegate, and refuse to return
// a value when anything fires -- not about the contents of the committed one. That the committed
// rules accept every committed instance is asserted where it belongs, by
// //config/manager_validator/go:validator_test, against the real artifacts.
func fixtureRules() *configpb.RuleSet {
	str := func(s string) *string { return &s }
	phase := configpb.Phase_PHASE_CONFIG
	localhost := configpb.EnvironmentKind_ENVIRONMENT_KIND_LOCALHOST

	return &configpb.RuleSet{Rules: []*configpb.Rule{
		{
			FieldPath: str("database.host"),
			Code:      str("DATABASE_HOST_REQUIRED"),
			Phase:     &phase,
			Predicate: &configpb.Rule_Required{Required: &configpb.Required{}},
		},
		{
			FieldPath: str("database.tls_mode"),
			Code:      str("DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST"),
			Phase:     &phase,
			Scope:     &configpb.Scope{ExceptKinds: []configpb.EnvironmentKind{localhost}},
			Predicate: &configpb.Rule_OneOf{OneOf: &configpb.OneOf{
				EnumValues: []string{"TLS_MODE_VERIFY_CA", "TLS_MODE_VERIFY_FULL"},
			}},
		},
	}}
}

// A valid ci instance, the baseline every mutation starts from.
func validCI() *configpb.EnvironmentConfig {
	str := func(s string) *string { return &s }
	u32 := func(v uint32) *uint32 { return &v }
	kind := configpb.EnvironmentKind_ENVIRONMENT_KIND_CI
	tls := configpb.TlsMode_TLS_MODE_VERIFY_FULL
	sec := configpb.SecurityMode_SECURITY_MODE_MTLS
	dtls := configpb.DgraphTlsMode_DGRAPH_TLS_MODE_VERIFY_CA

	return &configpb.EnvironmentConfig{
		Kind: &kind,
		Database: &configpb.DatabaseConfig{
			Host: str("db"), Port: u32(5432), Database: str("srql_fixture"),
			ConnectingRole: str("srql_test"), OwningRole: str("srql_test"),
			TlsMode: &tls, TlsServerName: str("db"),
			SearchPath: str("platform, ag_catalog"), PoolSize: u32(10),
			QueueTargetMs: u32(500), QueueIntervalMs: u32(1000), OwnershipTimeoutMs: u32(60000),
		},
		Nats: &configpb.NatsConfig{Url: str("nats://nats:4222"), ServerName: str("nats")},
		Core: &configpb.CoreConfig{
			Address: str("core:50052"), ApiUrl: str("http://core:8090"),
			SecurityMode: &sec, ServerName: str("core"),
		},
		Dgraph: &configpb.DgraphConfig{Host: str("dgraph"), Port: u32(9080), TlsMode: &dtls},
	}
}

func encode(cfg proto.Message) []byte {
	b, err := proto.Marshal(cfg)
	if err != nil {
		panic(err)
	}
	return b
}

// A mount that is not there.
type missingMount struct{}

func (missingMount) Read(path string) ([]byte, error) {
	return nil, &notFound{path}
}

type notFound struct{ path string }

func (e *notFound) Error() string { return "no such file: " + e.path }

// A mount carrying exactly these bytes.
type mounted struct{ bytes []byte }

func (m mounted) Read(string) ([]byte, error) { return m.bytes, nil }
