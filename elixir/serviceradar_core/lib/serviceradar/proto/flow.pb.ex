defmodule Flowpb.FlowMessage.FlowType do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :FLOWUNKNOWN, 0
  field :SFLOW_5, 1
  field :NETFLOW_V5, 2
  field :NETFLOW_V9, 3
  field :IPFIX, 4
end

defmodule Flowpb.FlowMessage.LayerStack do
  @moduledoc false

  use Protobuf, enum: true, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :Ethernet, 0
  field :IPv4, 1
  field :IPv6, 2
  field :TCP, 3
  field :UDP, 4
  field :MPLS, 5
  field :Dot1Q, 6
  field :ICMP, 7
  field :ICMPv6, 8
  field :GRE, 9
  field :IPv6HeaderRouting, 10
  field :IPv6HeaderFragment, 11
  field :Geneve, 12
  field :Teredo, 13
  field :Custom, 99
end

defmodule Flowpb.FlowMessage do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.13.0"

  field :type, 1, type: Flowpb.FlowMessage.FlowType, enum: true
  field :time_received_ns, 110, type: :uint64, json_name: "timeReceivedNs"
  field :sequence_num, 4, type: :uint32, json_name: "sequenceNum"
  field :sampling_rate, 3, type: :uint64, json_name: "samplingRate"
  field :sampler_address, 11, type: :bytes, json_name: "samplerAddress"
  field :time_flow_start_ns, 111, type: :uint64, json_name: "timeFlowStartNs"
  field :time_flow_end_ns, 112, type: :uint64, json_name: "timeFlowEndNs"
  field :bytes, 9, type: :uint64
  field :packets, 10, type: :uint64
  field :src_addr, 6, type: :bytes, json_name: "srcAddr"
  field :dst_addr, 7, type: :bytes, json_name: "dstAddr"
  field :etype, 30, type: :uint32
  field :proto, 20, type: :uint32
  field :src_port, 21, type: :uint32, json_name: "srcPort"
  field :dst_port, 22, type: :uint32, json_name: "dstPort"
  field :in_if, 18, type: :uint32, json_name: "inIf"
  field :out_if, 19, type: :uint32, json_name: "outIf"
  field :src_mac, 27, type: :uint64, json_name: "srcMac"
  field :dst_mac, 28, type: :uint64, json_name: "dstMac"
  field :src_vlan, 33, type: :uint32, json_name: "srcVlan"
  field :dst_vlan, 34, type: :uint32, json_name: "dstVlan"
  field :vlan_id, 29, type: :uint32, json_name: "vlanId"
  field :ip_tos, 23, type: :uint32, json_name: "ipTos"
  field :forwarding_status, 24, type: :uint32, json_name: "forwardingStatus"
  field :ip_ttl, 25, type: :uint32, json_name: "ipTtl"
  field :ip_flags, 38, type: :uint32, json_name: "ipFlags"
  field :tcp_flags, 26, type: :uint32, json_name: "tcpFlags"
  field :icmp_type, 31, type: :uint32, json_name: "icmpType"
  field :icmp_code, 32, type: :uint32, json_name: "icmpCode"
  field :ipv6_flow_label, 37, type: :uint32, json_name: "ipv6FlowLabel"
  field :fragment_id, 35, type: :uint32, json_name: "fragmentId"
  field :fragment_offset, 36, type: :uint32, json_name: "fragmentOffset"
  field :src_as, 14, type: :uint32, json_name: "srcAs"
  field :dst_as, 15, type: :uint32, json_name: "dstAs"
  field :next_hop, 12, type: :bytes, json_name: "nextHop"
  field :next_hop_as, 13, type: :uint32, json_name: "nextHopAs"
  field :src_net, 16, type: :uint32, json_name: "srcNet"
  field :dst_net, 17, type: :uint32, json_name: "dstNet"
  field :bgp_next_hop, 100, type: :bytes, json_name: "bgpNextHop"
  field :bgp_communities, 101, repeated: true, type: :uint32, json_name: "bgpCommunities"
  field :as_path, 102, repeated: true, type: :uint32, json_name: "asPath"
  field :mpls_ttl, 80, repeated: true, type: :uint32, json_name: "mplsTtl"
  field :mpls_label, 81, repeated: true, type: :uint32, json_name: "mplsLabel"
  field :mpls_ip, 82, repeated: true, type: :bytes, json_name: "mplsIp"
  field :observation_domain_id, 70, type: :uint32, json_name: "observationDomainId"
  field :observation_point_id, 71, type: :uint32, json_name: "observationPointId"
  field :layer_stack, 103, repeated: true, type: Flowpb.FlowMessage.LayerStack, json_name: "layerStack", enum: true
  field :layer_size, 104, repeated: true, type: :uint32, json_name: "layerSize"
  field :ipv6_routing_header_addresses, 105, repeated: true, type: :bytes, json_name: "ipv6RoutingHeaderAddresses"
  field :ipv6_routing_header_seg_left, 106, type: :uint32, json_name: "ipv6RoutingHeaderSegLeft"
  field :protocol_name, 107, type: :string, json_name: "protocolName"
end
