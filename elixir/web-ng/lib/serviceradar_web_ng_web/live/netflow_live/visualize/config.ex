defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.Config do
  @moduledoc false

  @default_limit 100
  @max_limit 200
  @default_time "last_1h"
  @default_bucket "5m"
  @chart_limit 4000

  @nf_dims_ordered [
    {"Protocol (group)", "protocol_group"},
    {"Application", "app"},
    {"Flow source", "flow_source"},
    {"Dest port", "dst_port"},
    {"Source IP", "src_ip"},
    {"Dest IP", "dst_ip"},
    {"Protocol (name)", "protocol_name"},
    {"Sampler address", "sampler_address"},
    {"Exporter name", "exporter_name"},
    {"In interface", "in_if_name"},
    {"Out interface", "out_if_name"},
    {"Source CIDR (Sankey/stats)", "src_cidr"},
    {"Dest CIDR (Sankey/stats)", "dst_cidr"}
  ]

  @sankey_src_dims [{"Source IP", "src_ip"}, {"Source CIDR", "src_cidr"}]
  @sankey_mid_dims [
    {"Dest port", "dst_port"},
    {"Application", "app"},
    {"Protocol (group)", "protocol_group"}
  ]
  @sankey_dst_dims [{"Dest IP", "dst_ip"}, {"Dest CIDR", "dst_cidr"}]

  def default_limit, do: @default_limit
  def max_limit, do: @max_limit
  def default_time, do: @default_time
  def default_bucket, do: @default_bucket
  def chart_limit, do: @chart_limit
  def nf_dims_ordered, do: @nf_dims_ordered
  def sankey_src_dims, do: @sankey_src_dims
  def sankey_mid_dims, do: @sankey_mid_dims
  def sankey_dst_dims, do: @sankey_dst_dims
end
