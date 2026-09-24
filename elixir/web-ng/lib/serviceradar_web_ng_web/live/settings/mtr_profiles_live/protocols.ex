defmodule ServiceRadarWebNGWeb.Settings.MtrProfilesLive.Protocols do
  @moduledoc """
  Protocol-set handling for the MTR profile form: reading the checkbox group
  from form params, and labelling a saved profile's set.
  """

  alias ServiceRadar.Observability.MtrPolicy

  @protocols ["icmp", "udp", "tcp"]

  @doc "Selected protocol names in icmp/udp/tcp order; blanks and unknown names are dropped."
  @spec normalize(term()) :: [String.t()]
  def normalize(values) do
    names = values |> List.wrap() |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    Enum.filter(@protocols, &(&1 in names))
  end

  @doc "The protocols selected in form params."
  @spec from_params(map()) :: [String.t()]
  def from_params(params) when is_map(params), do: normalize(Map.get(params, "baseline_protocols"))

  def from_params(_params), do: []

  @doc "How many traces each target gets per run; at least one."
  @spec count(map()) :: pos_integer()
  def count(params), do: params |> from_params() |> length() |> max(1)

  @doc "Scales a target count by the protocol set size; an unknown count stays unknown."
  @spec scaled_target_count(integer() | nil, integer() | nil) :: integer() | nil
  def scaled_target_count(count, protocol_count) when is_integer(count) and is_integer(protocol_count) do
    count * max(protocol_count, 1)
  end

  def scaled_target_count(_count, _protocol_count), do: nil

  @doc "Display label for a profile's protocol set, with the port when TCP is included."
  @spec label(map()) :: String.t()
  def label(profile) do
    names = MtrPolicy.protocol_names(profile)
    label = Enum.map_join(names, " + ", &String.upcase/1)

    if "tcp" in names, do: "#{label} (TCP #{MtrPolicy.tcp_port(profile)})", else: label
  end
end
