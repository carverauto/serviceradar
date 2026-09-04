defmodule Serviceradar.Agent.Netprobe.V1.CaptureDirection do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.agent.netprobe.v1.CaptureDirection",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :CAPTURE_DIRECTION_UNSPECIFIED, 0
  field :CAPTURE_DIRECTION_BOTH, 1
  field :CAPTURE_DIRECTION_INGRESS, 2
  field :CAPTURE_DIRECTION_EGRESS, 3
end

defmodule Serviceradar.Agent.Netprobe.V1.CaptureTerminationReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.agent.netprobe.v1.CaptureTerminationReason",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :CAPTURE_TERMINATION_REASON_UNSPECIFIED, 0
  field :CAPTURE_TERMINATION_REASON_DURATION_CAP, 1
  field :CAPTURE_TERMINATION_REASON_BYTE_CAP, 2
  field :CAPTURE_TERMINATION_REASON_CLIENT_CANCEL, 3
  field :CAPTURE_TERMINATION_REASON_AGENT_DISCONNECT, 4
  field :CAPTURE_TERMINATION_REASON_FILTER_ERROR, 5
  field :CAPTURE_TERMINATION_REASON_INTERFACE_DOWN, 6
end

defmodule Serviceradar.Agent.Netprobe.V1.DeviceCensusKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "serviceradar.agent.netprobe.v1.DeviceCensusKind",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :DEVICE_CENSUS_KIND_UNSPECIFIED, 0
  field :DEVICE_CENSUS_KIND_ARP_REQUEST, 1
  field :DEVICE_CENSUS_KIND_ARP_REPLY, 2
  field :DEVICE_CENSUS_KIND_IPV6_NDP, 3
end

defmodule Serviceradar.Agent.Netprobe.V1.NetprobeFrame do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.NetprobeFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:payload, 0)

  field :sequence, 1, type: :uint64

  field :apply_config, 2,
    type: Serviceradar.Agent.Netprobe.V1.ApplyConfig,
    json_name: "applyConfig",
    oneof: 0

  field :config_ack, 3,
    type: Serviceradar.Agent.Netprobe.V1.ConfigAck,
    json_name: "configAck",
    oneof: 0

  field :ping, 4, type: Serviceradar.Agent.Netprobe.V1.Ping, oneof: 0
  field :ping_ack, 5, type: Serviceradar.Agent.Netprobe.V1.PingAck, json_name: "pingAck", oneof: 0

  field :fingerprint_event, 6,
    type: Serviceradar.Agent.Netprobe.V1.FingerprintEvent,
    json_name: "fingerprintEvent",
    oneof: 0

  field :error, 7, type: Serviceradar.Agent.Netprobe.V1.ErrorFrame, oneof: 0

  field :dpi_event, 20,
    type: Serviceradar.Agent.Netprobe.V1.DpiEvent,
    json_name: "dpiEvent",
    oneof: 0

  field :flow_attribution_event, 21,
    type: Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent,
    json_name: "flowAttributionEvent",
    oneof: 0

  field :process_snapshot, 22,
    type: Serviceradar.Agent.Netprobe.V1.ProcessSnapshot,
    json_name: "processSnapshot",
    oneof: 0

  field :external_flow_record, 23,
    type: Serviceradar.Agent.Netprobe.V1.ExternalFlowRecord,
    json_name: "externalFlowRecord",
    oneof: 0

  field :start_remote_capture, 24,
    type: Serviceradar.Agent.Netprobe.V1.StartRemoteCapture,
    json_name: "startRemoteCapture",
    oneof: 0

  field :pcapng_block, 25,
    type: Serviceradar.Agent.Netprobe.V1.PcapngBlock,
    json_name: "pcapngBlock",
    oneof: 0

  field :banner_batch, 26,
    type: Serviceradar.Agent.Netprobe.V1.BannerBatch,
    json_name: "bannerBatch",
    oneof: 0

  field :banner_match_batch, 27,
    type: Serviceradar.Agent.Netprobe.V1.BannerMatchBatch,
    json_name: "bannerMatchBatch",
    oneof: 0

  field :external_flow_ack, 28,
    type: Serviceradar.Agent.Netprobe.V1.ExternalFlowAck,
    json_name: "externalFlowAck",
    oneof: 0

  field :flow_attribution_batch, 29,
    type: Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch,
    json_name: "flowAttributionBatch",
    oneof: 0

  field :device_census_snapshot, 30,
    type: Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot,
    json_name: "deviceCensusSnapshot",
    oneof: 0

  field :mdns_snapshot, 31,
    type: Serviceradar.Agent.Netprobe.V1.MdnsSnapshot,
    json_name: "mdnsSnapshot",
    oneof: 0
end

defmodule Serviceradar.Agent.Netprobe.V1.ApplyConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ApplyConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config, 1, type: Serviceradar.Agent.Netprobe.V1.VisibilityAgentConfig
end

defmodule Serviceradar.Agent.Netprobe.V1.ConfigAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ConfigAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :config_hash, 1, type: :string, json_name: "configHash"
end

defmodule Serviceradar.Agent.Netprobe.V1.Ping do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.Ping",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sent_at_unix_nano, 1, type: :int64, json_name: "sentAtUnixNano"
end

defmodule Serviceradar.Agent.Netprobe.V1.PingAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.PingAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :sent_at_unix_nano, 1, type: :int64, json_name: "sentAtUnixNano"
  field :acked_at_unix_nano, 2, type: :int64, json_name: "ackedAtUnixNano"
  field :fingerprint_engine_version, 3, type: :string, json_name: "fingerprintEngineVersion"
  field :running_as_root, 4, type: :bool, json_name: "runningAsRoot"
  field :p0f_corpus_revision, 5, type: :string, json_name: "p0fCorpusRevision"

  field :serviceradar_additions_revision, 6,
    type: :string,
    json_name: "serviceradarAdditionsRevision"

  field :ja4_spec_revision, 7, type: :string, json_name: "ja4SpecRevision"
  field :muonfp_corpus_revision, 8, type: :string, json_name: "muonfpCorpusRevision"
  field :recog_corpus_revision, 9, type: :string, json_name: "recogCorpusRevision"
  field :satori_corpus_revision, 10, type: :string, json_name: "satoriCorpusRevision"

  field :serviceradar_recog_additions_revision, 11,
    type: :string,
    json_name: "serviceradarRecogAdditionsRevision"

  field :recog_corpus_loaded, 12, type: :bool, json_name: "recogCorpusLoaded"
end

defmodule Serviceradar.Agent.Netprobe.V1.ErrorFrame do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ErrorFrame",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :string
  field :message, 2, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.VisibilityAgentConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.VisibilityAgentConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :capture_interfaces, 2, repeated: true, type: :string, json_name: "captureInterfaces"

  field :device_bindings, 3,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.DeviceBinding,
    json_name: "deviceBindings"

  field :default_sample_interval_ms, 4, type: :uint32, json_name: "defaultSampleIntervalMs"
  field :dpi, 20, type: Serviceradar.Agent.Netprobe.V1.DpiConfig
  field :flow_table_max_entries, 40, type: :uint32, json_name: "flowTableMaxEntries"
  field :process_snapshot_interval_s, 41, type: :uint32, json_name: "processSnapshotIntervalS"
  field :external_flow_match_window_ms, 42, type: :uint32, json_name: "externalFlowMatchWindowMs"
  field :flow_attribution_ipc_batch, 43, type: :bool, json_name: "flowAttributionIpcBatch"

  field :emit_raw_flow_attribution_events, 44,
    type: :bool,
    json_name: "emitRawFlowAttributionEvents"

  field :collector_ip, 48, type: :string, json_name: "collectorIp"
end

defmodule Serviceradar.Agent.Netprobe.V1.DeviceBinding do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DeviceBinding",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ip, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :profile_name, 3, type: :string, json_name: "profileName"
  field :fingerprint, 4, type: Serviceradar.Agent.Netprobe.V1.FingerprintConfig
  field :sample_interval_ms, 5, type: :uint32, json_name: "sampleIntervalMs"
  field :dpi, 6, type: Serviceradar.Agent.Netprobe.V1.DpiConfig
end

defmodule Serviceradar.Agent.Netprobe.V1.FingerprintConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FingerprintConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :tcp, 1, type: :bool
  field :tls, 2, type: :bool
  field :http, 3, type: :bool
end

defmodule Serviceradar.Agent.Netprobe.V1.DpiConfig do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DpiConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :protocols, 2, repeated: true, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.FingerprintEvent do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FingerprintEvent",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:evidence, 0)

  field :ip, 1, type: :string
  field :profile_id, 2, type: :string, json_name: "profileId"
  field :interface_name, 3, type: :string, json_name: "interfaceName"
  field :observed_at_unix_nano, 4, type: :int64, json_name: "observedAtUnixNano"
  field :tcp, 10, type: Serviceradar.Agent.Netprobe.V1.TcpFingerprint, oneof: 0, deprecated: true
  field :tls, 11, type: Serviceradar.Agent.Netprobe.V1.TlsFingerprint, oneof: 0, deprecated: true

  field :http, 12,
    type: Serviceradar.Agent.Netprobe.V1.HttpFingerprint,
    oneof: 0,
    deprecated: true

  field :license_clean, 13,
    type: Serviceradar.Agent.Netprobe.V1.LicenseCleanFingerprint,
    json_name: "licenseClean",
    oneof: 0
end

defmodule Serviceradar.Agent.Netprobe.V1.LicenseCleanFingerprint do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.LicenseCleanFingerprint",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Serviceradar.Agent.Netprobe.V1.FingerprintMatch
  alias Serviceradar.Agent.Netprobe.V1.RecogFingerprintMatch

  field :p0f_signature, 1, type: :string, json_name: "p0fSignature"

  field :p0f_match, 2,
    type: Serviceradar.Agent.Netprobe.V1.P0fFingerprintMatch,
    json_name: "p0fMatch"

  field :ja4, 3, type: :string

  field :ja4_match, 4,
    type: FingerprintMatch,
    json_name: "ja4Match"

  field :hassh, 5, type: :string
  field :hassh_server, 6, type: :string, json_name: "hasshServer"

  field :hassh_match, 7,
    type: FingerprintMatch,
    json_name: "hasshMatch"

  field :os_match, 8, type: Serviceradar.Agent.Netprobe.V1.OsMatch, json_name: "osMatch"
  field :agreement_count, 9, type: :uint32, json_name: "agreementCount"
  field :muonfp, 10, type: Serviceradar.Agent.Netprobe.V1.MuonFpFingerprintMatch

  field :recog_http, 11,
    type: RecogFingerprintMatch,
    json_name: "recogHttp"

  field :recog_ssh, 12,
    type: RecogFingerprintMatch,
    json_name: "recogSsh"

  field :recog_smb, 13,
    type: RecogFingerprintMatch,
    json_name: "recogSmb"

  field :recog_ftp, 14,
    type: RecogFingerprintMatch,
    json_name: "recogFtp"

  field :recog_telnet, 15,
    type: RecogFingerprintMatch,
    json_name: "recogTelnet"

  field :recog_snmp, 16,
    type: RecogFingerprintMatch,
    json_name: "recogSnmp"

  field :recog_sip, 17,
    type: RecogFingerprintMatch,
    json_name: "recogSip"

  field :recog_rdp, 18,
    type: RecogFingerprintMatch,
    json_name: "recogRdp"

  field :recog_dns, 19,
    type: RecogFingerprintMatch,
    json_name: "recogDns"

  field :satori_matches, 20,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.SatoriFingerprintMatch,
    json_name: "satoriMatches"

  field :tcp_observed, 21, type: :bool, json_name: "tcpObserved"
  field :ja4_observed, 22, type: :bool, json_name: "ja4Observed"
  field :hassh_observed, 23, type: :bool, json_name: "hasshObserved"
  field :dhcp_observed, 24, type: :bool, json_name: "dhcpObserved"
  field :dhcpv6_observed, 25, type: :bool, json_name: "dhcpv6Observed"
  field :http_observed, 26, type: :bool, json_name: "httpObserved"
  field :ssh_observed, 27, type: :bool, json_name: "sshObserved"
  field :smb_observed, 28, type: :bool, json_name: "smbObserved"
  field :dns_observed, 29, type: :bool, json_name: "dnsObserved"
  field :icmp_observed, 30, type: :bool, json_name: "icmpObserved"
  field :ntp_observed, 31, type: :bool, json_name: "ntpObserved"
  field :sip_observed, 32, type: :bool, json_name: "sipObserved"

  field :recog_smtp, 33,
    type: RecogFingerprintMatch,
    json_name: "recogSmtp"

  field :recog_ntp, 34,
    type: RecogFingerprintMatch,
    json_name: "recogNtp"
end

defmodule Serviceradar.Agent.Netprobe.V1.P0fFingerprintMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.P0fFingerprintMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :name, 2, type: :string
  field :version_flavor, 3, type: :string, json_name: "versionFlavor"
  field :os_family, 4, type: :string, json_name: "osFamily"
end

defmodule Serviceradar.Agent.Netprobe.V1.MuonFpFingerprintMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.MuonFpFingerprintMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :signature, 1, type: :string
  field :label, 2, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.RecogFingerprintMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.RecogFingerprintMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :product, 1, type: :string
  field :version, 2, type: :string
  field :os_family, 3, type: :string, json_name: "osFamily"
end

defmodule Serviceradar.Agent.Netprobe.V1.SatoriFingerprintMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.SatoriFingerprintMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :axis, 1, type: :string
  field :signature, 2, type: :string
  field :label, 3, type: :string
  field :device_class, 4, type: :string, json_name: "deviceClass"
  field :os_family, 5, type: :string, json_name: "osFamily"
end

defmodule Serviceradar.Agent.Netprobe.V1.FingerprintMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FingerprintMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version_range, 2, type: :string, json_name: "versionRange"
  field :os_family, 3, type: :string, json_name: "osFamily"
end

defmodule Serviceradar.Agent.Netprobe.V1.OsMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.OsMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :version_range, 2, type: :string, json_name: "versionRange"
  field :os_family, 3, type: :string, json_name: "osFamily"
  field :confidence, 4, type: :float

  field :disagreements, 5,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.FingerprintDisagreement
end

defmodule Serviceradar.Agent.Netprobe.V1.FingerprintDisagreement do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FingerprintDisagreement",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :signal, 1, type: :string
  field :signature, 2, type: :string
  field :observed_family, 3, type: :string, json_name: "observedFamily"
  field :observed_name, 4, type: :string, json_name: "observedName"
  field :version_range, 5, type: :string, json_name: "versionRange"
end

defmodule Serviceradar.Agent.Netprobe.V1.TcpFingerprint do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.TcpFingerprint",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :signature, 1, type: :string
  field :os_family, 2, type: :string, json_name: "osFamily"
  field :os_name, 3, type: :string, json_name: "osName"
  field :confidence, 4, type: :float
  field :ttl, 5, type: :uint32
  field :window_size, 6, type: :string, json_name: "windowSize"
  field :mss, 7, type: :uint32
  field :options_layout, 8, repeated: true, type: :string, json_name: "optionsLayout"
  field :quirks, 9, repeated: true, type: :string
  field :ip_version, 10, type: :string, json_name: "ipVersion"
  field :window_scale, 11, type: :uint32, json_name: "windowScale"
  field :payload_class, 12, type: :string, json_name: "payloadClass"
end

defmodule Serviceradar.Agent.Netprobe.V1.TlsFingerprint do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.TlsFingerprint",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :ja4, 1, type: :string
  field :ja4s, 2, type: :string
  field :sni_redacted, 3, type: :string, json_name: "sniRedacted"
end

defmodule Serviceradar.Agent.Netprobe.V1.HttpFingerprint do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.HttpFingerprint",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :user_agent, 1, type: :string, json_name: "userAgent"
  field :server, 2, type: :string
  field :accept_language, 3, type: :string, json_name: "acceptLanguage"
end

defmodule Serviceradar.Agent.Netprobe.V1.DpiEvent do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DpiEvent",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :source_ip, 1, type: :string, json_name: "sourceIp"
  field :destination_ip, 2, type: :string, json_name: "destinationIp"
  field :source_port, 3, type: :uint32, json_name: "sourcePort"
  field :destination_port, 4, type: :uint32, json_name: "destinationPort"
  field :transport_protocol, 5, type: :string, json_name: "transportProtocol"
  field :protocol, 6, type: :string
  field :confidence, 7, type: :float
  field :observed_at_unix_nano, 8, type: :int64, json_name: "observedAtUnixNano"
  field :interface_name, 9, type: :string, json_name: "interfaceName"
  field :profile_id, 10, type: :string, json_name: "profileId"
  field :dissector_id, 11, type: :string, json_name: "dissectorId"
end

defmodule Serviceradar.Agent.Netprobe.V1.WorkloadIdentity.LabelsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.WorkloadIdentity.LabelsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.WorkloadIdentity.AnnotationsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.WorkloadIdentity.AnnotationsEntry",
    map: true,
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.WorkloadIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.WorkloadIdentity",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :pod_sandbox_id, 1, type: :string, json_name: "podSandboxId"
  field :pod_name, 2, type: :string, json_name: "podName"
  field :pod_namespace, 3, type: :string, json_name: "podNamespace"
  field :pod_uid, 4, type: :string, json_name: "podUid"
  field :container_id, 5, type: :string, json_name: "containerId"
  field :container_name, 6, type: :string, json_name: "containerName"
  field :image, 7, type: :string
  field :image_ref, 8, type: :string, json_name: "imageRef"
  field :runtime_pid, 9, type: :uint32, json_name: "runtimePid"
  field :cgroup_path, 10, type: :string, json_name: "cgroupPath"
  field :runtime_source, 11, type: :string, json_name: "runtimeSource"
  field :confidence, 12, type: :string
  field :degradation_reason, 13, type: :string, json_name: "degradationReason"

  field :labels, 14,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.WorkloadIdentity.LabelsEntry,
    map: true

  field :annotations, 15,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.WorkloadIdentity.AnnotationsEntry,
    map: true
end

defmodule Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FlowAttributionEvent",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :local_ip, 1, type: :string, json_name: "localIp"
  field :local_port, 2, type: :uint32, json_name: "localPort"
  field :remote_ip, 3, type: :string, json_name: "remoteIp"
  field :remote_port, 4, type: :uint32, json_name: "remotePort"
  field :transport_protocol, 5, type: :string, json_name: "transportProtocol"
  field :pid, 6, type: :uint32
  field :tgid, 7, type: :uint32
  field :uid, 8, type: :uint32
  field :gid, 9, type: :uint32
  field :comm, 10, type: :string
  field :redacted_cmdline, 11, repeated: true, type: :string, json_name: "redactedCmdline"
  field :container_id, 12, type: :string, json_name: "containerId"
  field :observed_at_unix_nano, 13, type: :int64, json_name: "observedAtUnixNano"
  field :socket_address, 14, type: :uint64, json_name: "socketAddress"
  field :event_kind, 15, type: :uint32, json_name: "eventKind"
  field :old_state, 16, type: :int32, json_name: "oldState"
  field :new_state, 17, type: :int32, json_name: "newState"
  field :source, 18, type: :string
  field :external_flow_id, 19, type: :uint64, json_name: "externalFlowId"

  field :workload_identity, 20,
    type: Serviceradar.Agent.Netprobe.V1.WorkloadIdentity,
    json_name: "workloadIdentity"
end

defmodule Serviceradar.Agent.Netprobe.V1.FlowAttributionEventBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FlowAttributionEventBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :events, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.FlowAttributionEvent
  field :batch_start_unix_nano, 2, type: :int64, json_name: "batchStartUnixNano"
  field :batch_end_unix_nano, 3, type: :int64, json_name: "batchEndUnixNano"
  field :dropped_since_last, 4, type: :uint32, json_name: "droppedSinceLast"
end

defmodule Serviceradar.Agent.Netprobe.V1.ProcessSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ProcessSnapshot",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :fingerprint, 1, type: :string
  field :observed_at_unix_nano, 2, type: :int64, json_name: "observedAtUnixNano"
  field :entries, 3, repeated: true, type: Serviceradar.Agent.Netprobe.V1.ProcessSnapshotEntry
end

defmodule Serviceradar.Agent.Netprobe.V1.ProcessSnapshotEntry do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ProcessSnapshotEntry",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :local_ip, 1, type: :string, json_name: "localIp"
  field :local_port, 2, type: :uint32, json_name: "localPort"
  field :transport_protocol, 3, type: :string, json_name: "transportProtocol"
  field :pid, 4, type: :uint32
  field :tgid, 5, type: :uint32
  field :uid, 6, type: :uint32
  field :gid, 7, type: :uint32
  field :comm, 8, type: :string
  field :redacted_cmdline, 9, repeated: true, type: :string, json_name: "redactedCmdline"
  field :container_id, 10, type: :string, json_name: "containerId"

  field :workload_identity, 11,
    type: Serviceradar.Agent.Netprobe.V1.WorkloadIdentity,
    json_name: "workloadIdentity"
end

defmodule Serviceradar.Agent.Netprobe.V1.ExternalFlowRecord do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ExternalFlowRecord",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :external_flow_id, 1, type: :uint64, json_name: "externalFlowId"
  field :source_ip, 2, type: :bytes, json_name: "sourceIp"
  field :destination_ip, 3, type: :bytes, json_name: "destinationIp"
  field :source_port, 4, type: :uint32, json_name: "sourcePort"
  field :destination_port, 5, type: :uint32, json_name: "destinationPort"
  field :transport_protocol, 6, type: :string, json_name: "transportProtocol"
  field :ip_protocol, 7, type: :uint32, json_name: "ipProtocol"
  field :time_flow_start_ns, 8, type: :uint64, json_name: "timeFlowStartNs"
  field :time_flow_end_ns, 9, type: :uint64, json_name: "timeFlowEndNs"
  field :bytes, 10, type: :uint64
  field :packets, 11, type: :uint64
  field :partition, 12, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.ExternalFlowAck do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ExternalFlowAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :accepted, 1, type: :uint64
  field :matched, 2, type: :uint64
  field :unmatched, 3, type: :uint64
  field :invalid, 4, type: :uint64
end

defmodule Serviceradar.Agent.Netprobe.V1.BpfInstruction do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BpfInstruction",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :code, 1, type: :uint32
  field :jt, 2, type: :uint32
  field :jf, 3, type: :uint32
  field :k, 4, type: :int64
end

defmodule Serviceradar.Agent.Netprobe.V1.StartRemoteCapture do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.StartRemoteCapture",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:filter, 0)

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :interfaces, 2, repeated: true, type: :string
  field :filter_expression, 3, type: :string, json_name: "filterExpression", oneof: 0

  field :filter_bpf, 4,
    type: Serviceradar.Agent.Netprobe.V1.BpfProgram,
    json_name: "filterBpf",
    oneof: 0

  field :snaplen, 5, type: :uint32
  field :duration_s, 6, type: :uint32, json_name: "durationS"
  field :byte_cap, 7, type: :uint64, json_name: "byteCap"
  field :direction, 8, type: Serviceradar.Agent.Netprobe.V1.CaptureDirection, enum: true
  field :promiscuous, 9, type: :bool
  field :actor, 10, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.BpfProgram do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BpfProgram",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :instructions, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.BpfInstruction
end

defmodule Serviceradar.Agent.Netprobe.V1.PcapngBlock do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.PcapngBlock",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :bytes, 2, type: :bytes
  field :final, 3, type: :bool

  field :termination_reason, 4,
    type: Serviceradar.Agent.Netprobe.V1.CaptureTerminationReason,
    json_name: "terminationReason",
    enum: true

  field :packets_captured, 5, type: :uint64, json_name: "packetsCaptured"
  field :packets_dropped, 6, type: :uint64, json_name: "packetsDropped"
  field :bytes_streamed, 7, type: :uint64, json_name: "bytesStreamed"
end

defmodule Serviceradar.Agent.Netprobe.V1.BannerObservation do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BannerObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :observation_id, 1, type: :uint64, json_name: "observationId"
  field :host, 2, type: :string
  field :port, 3, type: :uint32
  field :protocol, 4, type: :string
  field :banner_bytes, 5, type: :bytes, json_name: "bannerBytes"
  field :observed_at, 6, type: :int64, json_name: "observedAt"
  field :source, 7, type: :string
end

defmodule Serviceradar.Agent.Netprobe.V1.BannerBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BannerBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :observations, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.BannerObservation
end

defmodule Serviceradar.Agent.Netprobe.V1.BannerMatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BannerMatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :observation_id, 1, type: :uint64, json_name: "observationId"
  field :corpus_label, 2, type: :string, json_name: "corpusLabel"
  field :os_family, 3, type: :string, json_name: "osFamily"
  field :product, 4, type: :string
  field :version, 5, type: :string
  field :confidence, 6, type: :double
  field :raw_pattern_id, 7, type: :string, json_name: "rawPatternId"
end

defmodule Serviceradar.Agent.Netprobe.V1.BannerMatchBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.BannerMatchBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :matches, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.BannerMatch
end

defmodule Serviceradar.Agent.Netprobe.V1.MdnsTxtPair do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.MdnsTxtPair",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :key, 1, type: :string
  field :value, 2, type: :string
  field :has_value, 3, type: :bool, json_name: "hasValue"
end

defmodule Serviceradar.Agent.Netprobe.V1.MdnsDevice do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.MdnsDevice",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :mac, 1, type: :string
  field :ip, 2, type: :string
  field :interface_index, 3, type: :uint32, json_name: "interfaceIndex"
  field :service_types, 4, repeated: true, type: :string, json_name: "serviceTypes"
  field :txt, 5, repeated: true, type: Serviceradar.Agent.Netprobe.V1.MdnsTxtPair
  field :models, 6, repeated: true, type: :string
  field :ambiguous_model, 7, type: :bool, json_name: "ambiguousModel"
  field :first_seen_unix_nano, 8, type: :int64, json_name: "firstSeenUnixNano"
  field :last_seen_unix_nano, 9, type: :int64, json_name: "lastSeenUnixNano"
  field :truncated, 10, type: :bool
end

defmodule Serviceradar.Agent.Netprobe.V1.MdnsSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.MdnsSnapshot",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :devices, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.MdnsDevice
  field :snapshot_id, 2, type: :string, json_name: "snapshotId"
  field :interface_name, 3, type: :string, json_name: "interfaceName"
  field :generated_at_unix_nano, 4, type: :int64, json_name: "generatedAtUnixNano"
  field :complete, 5, type: :bool
  field :chunk_index, 6, type: :uint32, json_name: "chunkIndex"
  field :chunk_count, 7, type: :uint32, json_name: "chunkCount"
  field :dropped_since_last, 8, type: :uint32, json_name: "droppedSinceLast"
end

defmodule Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DeviceCensusObservation",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :mac, 1, type: :string
  field :ip, 2, type: :string
  field :interface_index, 3, type: :uint32, json_name: "interfaceIndex"
  field :kind, 4, type: Serviceradar.Agent.Netprobe.V1.DeviceCensusKind, enum: true
  field :first_seen_unix_nano, 5, type: :int64, json_name: "firstSeenUnixNano"
  field :last_seen_unix_nano, 6, type: :int64, json_name: "lastSeenUnixNano"
  field :randomized_mac, 7, type: :bool, json_name: "randomizedMac"
  field :off_segment, 8, type: :bool, json_name: "offSegment"
end

defmodule Serviceradar.Agent.Netprobe.V1.DeviceCensusSnapshot do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DeviceCensusSnapshot",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :observations, 1,
    repeated: true,
    type: Serviceradar.Agent.Netprobe.V1.DeviceCensusObservation

  field :snapshot_id, 2, type: :string, json_name: "snapshotId"
  field :interface_name, 3, type: :string, json_name: "interfaceName"
  field :generated_at_unix_nano, 4, type: :int64, json_name: "generatedAtUnixNano"
  field :complete, 5, type: :bool
  field :chunk_index, 6, type: :uint32, json_name: "chunkIndex"
  field :chunk_count, 7, type: :uint32, json_name: "chunkCount"
  field :dropped_since_last, 8, type: :uint32, json_name: "droppedSinceLast"
end

defmodule Serviceradar.Agent.Netprobe.V1.FingerprintEventBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.FingerprintEventBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :events, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.FingerprintEvent
  field :batch_start_unix_nano, 2, type: :int64, json_name: "batchStartUnixNano"
  field :batch_end_unix_nano, 3, type: :int64, json_name: "batchEndUnixNano"
  field :dropped_since_last, 4, type: :uint32, json_name: "droppedSinceLast"
end

defmodule Serviceradar.Agent.Netprobe.V1.DpiEventBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.DpiEventBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :events, 1, repeated: true, type: Serviceradar.Agent.Netprobe.V1.DpiEvent
  field :batch_start_unix_nano, 2, type: :int64, json_name: "batchStartUnixNano"
  field :batch_end_unix_nano, 3, type: :int64, json_name: "batchEndUnixNano"
  field :dropped_since_last, 4, type: :uint32, json_name: "droppedSinceLast"
  field :subject_ips, 5, repeated: true, type: :string, json_name: "subjectIps"
end

defmodule Serviceradar.Agent.Netprobe.V1.ProcessSnapshotBatch do
  @moduledoc false

  use Protobuf,
    full_name: "serviceradar.agent.netprobe.v1.ProcessSnapshotBatch",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :snapshot, 1, type: Serviceradar.Agent.Netprobe.V1.ProcessSnapshot
  field :subject_ip, 2, type: :string, json_name: "subjectIp"
end
