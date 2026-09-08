defmodule ServiceRadar.NetworkDiscovery.Changes.NormalizeUnifiBaseUrl do
  @moduledoc """
  Normalizes and validates UniFi controller URLs.

  Accepted inputs:
  - Host URL only, e.g. `https://192.168.10.1` (path auto-appended)
  - Full integration URL, e.g. `https://192.168.10.1/proxy/network/integration/v1`
  """

  use Ash.Resource.Change

  alias ServiceRadar.NetworkDiscovery.Changes.NormalizeControllerBaseUrl

  @required_path "/proxy/network/integration/v1"

  @impl true
  def change(changeset, _opts, _context) do
    NormalizeControllerBaseUrl.change(changeset, @required_path)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
