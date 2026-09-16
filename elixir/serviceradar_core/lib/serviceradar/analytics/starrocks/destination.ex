defmodule ServiceRadar.Analytics.StarRocks.Destination do
  @moduledoc """
  EventWriter destination seam for opt-in StarRocks shadow writes.

  CNPG remains the serving authority while shadowing. Each destination is
  tracked independently: a partial success retries only the missing destination
  with the same stable identities. Shadow failure does not fail JetStream ACK
  until the dataset is listed in `cutover_datasets`; then Stream Load Success
  or durable quarantine is required before ACK.
  """

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.Rows
  alias ServiceRadar.Analytics.StarRocks.StreamLoad

  require Logger

  @type dataset :: :flows | :flow_attribution | :metrics | :logs | :events
  @type dest :: :cnpg | :starrocks

  @tables %{
    flows: "ocsf_network_activity",
    flow_attribution: "ocsf_network_activity",
    metrics: "timeseries_metrics",
    logs: "logs",
    events: "events"
  }

  @spec table_for(dataset()) :: String.t()
  def table_for(dataset) when is_map_key(@tables, dataset), do: Map.fetch!(@tables, dataset)

  @spec maybe_shadow(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:error, term()}
  def maybe_shadow(dataset, rows, opts \\ [])

  def maybe_shadow(_dataset, [], _opts), do: {:ok, :disabled}

  def maybe_shadow(dataset, rows, opts) when is_list(rows) do
    if shadow_enabled?(dataset, opts) do
      persist_shadow(dataset, rows, opts)
    else
      {:ok, :disabled}
    end
  rescue
    error ->
      Logger.error("StarRocks shadow persist crashed",
        dataset: dataset,
        error: Exception.message(error)
      )

      {:error, error}
  end

  @doc """
  After a CNPG insert, persist to StarRocks.

  When `Readers.mode_for/1` is `starrocks`, Stream Load Success or durable
  quarantine is required and a failure fails the EventWriter ACK. Otherwise
  shadow writes stay best-effort.
  """
  @spec persist_after_cnpg(dataset(), [map()], keyword()) ::
          {:ok, map()} | {:ok, :disabled} | {:error, term()}
  def persist_after_cnpg(dataset, rows, opts \\ [])

  def persist_after_cnpg(_dataset, [], _opts), do: {:ok, :disabled}

  def persist_after_cnpg(dataset, rows, opts) when is_list(rows) do
    if Readers.mode_for(dataset) == "starrocks" do
      persist_shadow(
        dataset,
        rows,
        opts
        |> Keyword.put(:completed, [:cnpg])
        |> Keyword.put(:require_all, true)
      )
    else
      maybe_shadow(dataset, rows, opts)
    end
  end

  @doc """
  Insert into CNPG then apply `persist_after_cnpg/3`. The insert function is
  the processor's existing CNPG writer.
  """
  @spec ack_cnpg_batch(
          dataset(),
          [map()],
          ([map()] -> {:ok, non_neg_integer()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ack_cnpg_batch(dataset, rows, insert_fun, opts \\ []) when is_function(insert_fun, 1) do
    with {:ok, count} <- insert_fun.(rows) do
      case persist_after_cnpg(dataset, rows, opts) do
        {:ok, _} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Persist to every destination not already listed in `:completed`.

  `completed` is a list of `:cnpg` and/or `:starrocks`. A retry after CNPG
  succeeded therefore loads StarRocks only.
  """
  @spec persist_shadow(dataset(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def persist_shadow(dataset, rows, opts \\ []) when is_list(rows) do
    completed = MapSet.new(Keyword.get(opts, :completed, []))
    encoded = Rows.encode(dataset, rows)

    cnpg_result = persist_cnpg(dataset, rows, completed, opts)
    starrocks_result = persist_starrocks(dataset, encoded, completed, opts)

    progress = %{
      dataset: dataset,
      completed: completed_dests(cnpg_result, starrocks_result, completed),
      missing: missing_dests(cnpg_result, starrocks_result, completed)
    }

    cond do
      progress.missing == [] ->
        {:ok, Map.put(progress, :loaded, length(encoded))}

      Keyword.get(opts, :require_all, false) ->
        {:error, {:missing_destinations, progress}}

      true ->
        {:ok, Map.put(progress, :partial, true)}
    end
  end

  defp persist_cnpg(_dataset, _rows, completed, _opts) do
    if MapSet.member?(completed, :cnpg) do
      :already
    else
      # CNPG write is owned by the EventWriter processor. Shadow tracking only
      # records that the processor already succeeded when `:completed` includes
      # `:cnpg`. A missing CNPG dest is a retry of the processor, not a second write.
      :skipped
    end
  end

  defp persist_starrocks(dataset, encoded, completed, opts) do
    if MapSet.member?(completed, :starrocks) do
      :already
    else
      table = table_for(dataset)
      persist = Keyword.get(opts, :persist, &StreamLoad.persist/3)

      persist_opts =
        opts
        |> Keyword.take([:http, :label, :config, :partial_update, :columns])
        |> Keyword.put_new(:config, client_config())
        |> attribution_load_opts(dataset)

      case persist.(table, encoded, persist_opts) do
        {:quarantine, reason} -> {:ok, %{quarantine: true, reason: reason}}
        other -> other
      end
    end
  end

  defp client_config do
    env = Application.get_env(:serviceradar_core, StarRocks, [])

    %{
      fe_http: Keyword.get(env, :fe_http, "http://127.0.0.1:8030"),
      database: Keyword.get(env, :database, "serviceradar"),
      user: Keyword.get(env, :user, "root"),
      password: Keyword.get(env, :password, "")
    }
  end

  defp completed_dests(cnpg_result, starrocks_result, completed) do
    completed
    |> maybe_put(:cnpg, cnpg_result)
    |> maybe_put(:starrocks, starrocks_result)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp missing_dests(cnpg_result, starrocks_result, completed) do
    []
    |> maybe_missing(:cnpg, cnpg_result, completed)
    |> maybe_missing(:starrocks, starrocks_result, completed)
    |> Enum.sort()
  end

  defp maybe_put(completed, dest, :already), do: MapSet.put(completed, dest)
  defp maybe_put(completed, dest, {:ok, _}), do: MapSet.put(completed, dest)
  defp maybe_put(completed, _dest, _), do: completed

  defp maybe_missing(missing, dest, result, completed) do
    cond do
      MapSet.member?(completed, dest) -> missing
      match?({:ok, _}, result) -> missing
      result == :already -> missing
      dest == :cnpg and result == :skipped -> missing
      true -> [dest | missing]
    end
  end

  defp attribution_load_opts(opts, :flow_attribution) do
    opts
    |> Keyword.put(:partial_update, true)
    |> Keyword.put(:columns, Attribution.load_columns())
  end

  defp attribution_load_opts(opts, _dataset), do: opts

  defp shadow_enabled?(dataset, opts) do
    enabled = enabled_datasets(opts)
    dataset in enabled or (dataset == :flow_attribution and :flows in enabled)
  end

  defp enabled_datasets(opts) do
    case Keyword.fetch(opts, :enabled) do
      {:ok, true} -> [:flows, :flow_attribution, :metrics, :logs, :events]
      {:ok, :all} -> [:flows, :flow_attribution, :metrics, :logs, :events]
      {:ok, value} when is_list(value) -> value
      :error -> configured_shadow_datasets()
      {:ok, _} -> []
    end
  end

  defp configured_shadow_datasets do
    :serviceradar_core
    |> Application.get_env(StarRocks, [])
    |> Keyword.get(:shadow_datasets, [])
  end
end
