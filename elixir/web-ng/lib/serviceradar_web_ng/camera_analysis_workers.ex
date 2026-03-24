defmodule ServiceRadarWebNG.CameraAnalysisWorkers do
  @moduledoc """
  Web-facing operations for camera analysis workers.
  """

  alias ServiceRadar.Camera.AnalysisWorker

  require Ash.Query

  def list_workers(opts \\ []) do
    scope = Keyword.fetch!(opts, :scope)
    limit = parse_limit(Keyword.get(opts, :limit))

    query =
      AnalysisWorker
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.sort(worker_id: :asc)
      |> maybe_filter_enabled(Keyword.get(opts, :enabled))
      |> maybe_limit(limit)

    Ash.read(query, scope: scope)
  end

  def get_worker(id, opts \\ []) when is_binary(id) do
    scope = Keyword.fetch!(opts, :scope)
    Ash.get(AnalysisWorker, id, scope: scope)
  end

  def create_worker(attrs, opts \\ []) when is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    AnalysisWorker
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create(scope: scope)
  end

  def update_worker(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    scope = Keyword.fetch!(opts, :scope)

    with {:ok, worker} when not is_nil(worker) <- get_worker(id, scope: scope) do
      worker
      |> Ash.Changeset.for_update(:update, attrs, scope: scope)
      |> Ash.update(scope: scope)
    end
  end

  def set_enabled(id, enabled, opts \\ []) when is_binary(id) and is_boolean(enabled) do
    update_worker(id, %{enabled: enabled}, opts)
  end

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled) when is_boolean(enabled), do: Ash.Query.filter(query, enabled == ^enabled)
  defp maybe_filter_enabled(query, _enabled), do: query

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: Ash.Query.limit(query, limit)

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp parse_limit(_limit), do: nil
end
