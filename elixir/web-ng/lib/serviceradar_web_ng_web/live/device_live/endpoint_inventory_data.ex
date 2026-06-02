defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData do
  @moduledoc false

  require Logger

  alias ServiceRadar.Inventory.EndpointInventoryArtifact
  alias ServiceRadar.Inventory.EndpointInventoryPackage
  alias ServiceRadar.Inventory.EndpointInventoryScan

  @scan_limit 8
  @package_limit 200

  def load(scope, device_uid) when is_binary(device_uid) and device_uid != "" do
    with {:ok, scans} <- read_current_scans(scope, device_uid),
         latest_scan <- List.first(scans),
         {:ok, packages} <- read_current_packages(scope, device_uid),
         {:ok, artifacts} <- read_artifacts(scope, latest_scan) do
      %{
        scan: latest_scan,
        scans: scans,
        packages: packages,
        artifacts: artifacts,
        error: nil,
        has_inventory: scans != [] or packages != []
      }
    else
      {:error, reason} ->
        Logger.warning("Failed to load endpoint inventory for #{device_uid}: #{inspect(reason)}")

        %{
          scan: nil,
          scans: [],
          packages: [],
          artifacts: [],
          error: "Failed to load endpoint software inventory.",
          has_inventory: true
        }
    end
  end

  def load(_scope, _device_uid) do
    %{
      scan: nil,
      scans: [],
      packages: [],
      artifacts: [],
      error: nil,
      has_inventory: false
    }
  end

  defp read_current_scans(scope, device_uid) do
    EndpointInventoryScan
    |> Ash.Query.for_read(:current_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@scan_limit)
    |> Ash.read(scope: scope)
  end

  defp read_current_packages(scope, device_uid) do
    EndpointInventoryPackage
    |> Ash.Query.for_read(:current_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@package_limit)
    |> Ash.read(scope: scope)
  end

  defp read_artifacts(_scope, nil), do: {:ok, []}

  defp read_artifacts(scope, scan) do
    EndpointInventoryArtifact
    |> Ash.Query.for_read(:by_scan, %{scan_ref: scan.id}, scope: scope)
    |> Ash.Query.limit(12)
    |> Ash.read(scope: scope)
  end
end
