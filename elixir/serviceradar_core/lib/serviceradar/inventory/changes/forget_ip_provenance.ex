defmodule ServiceRadar.Inventory.Changes.ForgetIpProvenance do
  @moduledoc """
  An update that writes `ip` without saying which source recorded it clears
  `ip_source` and `ip_seen_at`, so they never describe an address the row no longer
  holds. A primary with no recorded source counts as absent from every source's
  sightings (`Sync.DeviceWrites`), so the next source that sights the device at an
  equally strong address records it. A caller that records its source sets both
  itself (`AgentGatewaySync`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if forget?(changeset) do
      changeset
      |> Ash.Changeset.force_change_attribute(:ip_source, nil)
      |> Ash.Changeset.force_change_attribute(:ip_seen_at, nil)
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    if forget?(changeset), do: {:atomic, %{ip_source: nil, ip_seen_at: nil}}, else: :ok
  end

  defp forget?(changeset) do
    Ash.Changeset.changing_attribute?(changeset, :ip) and
      not Ash.Changeset.changing_attribute?(changeset, :ip_source)
  end
end
