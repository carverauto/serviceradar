defmodule ServiceRadar.NetworkConfig.Native do
  @moduledoc """
  Rustler NIF bindings for `network-config-downparser`.

  The BEAM-visible seam for V1 config parse. Callers should use
  `ServiceRadar.NetworkConfig.Downparser`.
  """

  use Rustler,
    otp_app: :serviceradar_core,
    crate: "network_config_nif"

  @type fact :: %{
          optional(:if_name) => String.t(),
          optional(:ipv4_prefix) => String.t() | nil,
          optional(:ipv6_prefix) => String.t() | nil,
          optional(:vlan) => integer() | nil,
          optional(:description) => String.t() | nil,
          optional(:shutdown) => boolean(),
          optional(:vrf) => String.t() | nil
        }

  @spec parse_running_config(String.t()) :: {:ok, [fact()]} | {:error, String.t()}
  def parse_running_config(_body), do: :erlang.nif_error(:nif_not_loaded)
end
