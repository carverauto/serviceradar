defmodule ServiceRadarWebNGWeb.DeviceLive.BumblebeeData do
  @moduledoc false

  alias ServiceRadar.Inventory.BumblebeeDevicePosture
  alias ServiceRadar.Inventory.BumblebeeFinding

  require Logger

  @posture_limit 8
  @finding_limit 25

  def load(scope, device_uid) when is_binary(device_uid) and device_uid != "" do
    with {:ok, postures} <- read_postures(scope, device_uid),
         {:ok, findings} <- read_findings(scope, device_uid) do
      %{
        postures: page_results(postures),
        findings: page_results(findings),
        error: nil,
        has_exposure: page_results(postures) != [] or page_results(findings) != []
      }
    else
      {:error, reason} ->
        Logger.warning("Failed to load Bumblebee exposure for #{device_uid}: #{inspect(reason)}")

        %{
          postures: [],
          findings: [],
          error: "Failed to load Bumblebee exposure findings.",
          has_exposure: true
        }
    end
  end

  def load(_scope, _device_uid) do
    %{postures: [], findings: [], error: nil, has_exposure: false}
  end

  defp read_postures(scope, device_uid) do
    BumblebeeDevicePosture
    |> Ash.Query.for_read(:by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@posture_limit)
    |> Ash.read(scope: scope)
  end

  defp read_findings(scope, device_uid) do
    BumblebeeFinding
    |> Ash.Query.for_read(:active_by_device, %{device_uid: device_uid}, scope: scope)
    |> Ash.Query.limit(@finding_limit)
    |> Ash.read(scope: scope)
  end

  defp page_results(%Ash.Page.Keyset{results: results}), do: results
  defp page_results(results) when is_list(results), do: results
  defp page_results(_results), do: []
end
