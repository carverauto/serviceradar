defmodule ServiceRadar.NetworkDiscovery.Changes.NormalizeMikrotikBaseUrl do
  @moduledoc """
  Normalizes and validates MikroTik RouterOS REST API URLs.

  Accepted inputs:
  - Host URL only, e.g. `https://192.168.88.1`
  - REST base URL, e.g. `https://192.168.88.1/rest`
  """

  use Ash.Resource.Change

  alias ServiceRadar.NetworkDiscovery.Changes.NormalizeControllerBaseUrl

  @required_path "/rest"

  @impl true
  def change(changeset, _opts, _context) do
    NormalizeControllerBaseUrl.change(changeset, @required_path)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end
