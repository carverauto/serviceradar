defmodule ServiceRadarCoreElx.CameraRecording.MemberStatus do
  @moduledoc """
  Bounded live `GET /v1/status` probe for configured NVR members.

  Runs inside `core-elx`, where the operator-mounted ingest client config and
  bearer token live, so `web-ng` can display live disk capacity and inventory
  ledger audit state on `/settings/recording?tab=health` without ever touching
  NVR bearer tokens or ingest mTLS credentials.
  """

  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig

  @default_timeout_ms 2_500
  @max_concurrency 4

  @doc """
  Queries `GET /v1/status` for each configured NVR member with a bounded
  per-member timeout and returns a map keyed by `storage_id`.

  Unreachable, timing-out, unconfigured, or mismatched-`storage_id` members are
  omitted rather than failing the call.
  """
  @spec fetch_all(keyword()) :: %{optional(String.t()) => map()}
  def fetch_all(opts \\ []) when is_list(opts) do
    timeout_ms = normalize_timeout(Keyword.get(opts, :timeout_ms, @default_timeout_ms))
    targets_loader = Keyword.get(opts, :targets_loader, fn -> NVRTargetConfig.list_all(opts) end)
    status_fn = Keyword.get(opts, :status_fn, &ServiceRadarNVRClient.status/2)

    case targets_loader.() do
      {:ok, targets} when is_list(targets) and targets != [] ->
        targets
        |> Task.async_stream(
          fn target -> fetch_target(target, status_fn, timeout_ms) end,
          max_concurrency: @max_concurrency,
          timeout: timeout_ms + 500,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.reduce(%{}, fn
          {:ok, {:ok, storage_id, status}}, acc -> Map.put(acc, storage_id, status)
          _, acc -> acc
        end)

      _ ->
        %{}
    end
  end

  defp fetch_target(%{storage_id: storage_id, client_config: client_config}, status_fn, timeout_ms)
       when is_binary(storage_id) do
    case status_fn.(client_config, timeout_ms) do
      {:ok, %{storage_id: ^storage_id} = status} ->
        {:ok, storage_id, sanitize_status(status)}

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp fetch_target(_target, _status_fn, _timeout_ms), do: :error

  defp sanitize_status(status) when is_map(status) do
    %{
      storage_id: Map.get(status, :storage_id),
      recovery: Map.get(status, :recovery),
      inventory: Map.get(status, :inventory),
      capacity: Map.get(status, :capacity),
      max_sessions: Map.get(status, :max_sessions),
      archive_busy: Map.get(status, :archive_busy),
      release: Map.get(status, :release)
    }
  end

  defp normalize_timeout(ms) when is_integer(ms) and ms in 100..30_000, do: ms
  defp normalize_timeout(_), do: @default_timeout_ms
end
