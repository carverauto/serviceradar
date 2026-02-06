defmodule Mdnspb.MdnsRecord.RecordType do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :UNKNOWN, 0
  field :A, 1
  field :AAAA, 2
  field :PTR, 3
end

defmodule Mdnspb.MdnsRecord do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :record_type, 1, type: Mdnspb.MdnsRecord.RecordType, json_name: "recordType", enum: true
  field :time_received_ns, 2, type: :uint64, json_name: "timeReceivedNs"
  field :source_ip, 3, type: :bytes, json_name: "sourceIp"
  field :hostname, 4, type: :string
  field :resolved_addr, 5, type: :bytes, json_name: "resolvedAddr"
  field :resolved_addr_str, 6, type: :string, json_name: "resolvedAddrStr"
  field :dns_ttl, 7, type: :uint32, json_name: "dnsTtl"
  field :dns_name, 8, type: :string, json_name: "dnsName"
  field :is_response, 9, type: :bool, json_name: "isResponse"
end
