defmodule ServiceRadarWebNGWeb.DeviceLive.IndexEvents.Helpers do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Changes.Required
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath
  alias ServiceRadarWebNGWeb.SRQL.Builder, as: SRQLBuilder

  def format_changeset_errors(changeset) do
    case changeset do
      %Ash.Changeset{errors: errors} when is_list(errors) and errors != [] ->
        Enum.map_join(errors, ", ", &format_single_error/1)

      %Ecto.Changeset{errors: errors} when is_list(errors) and errors != [] ->
        Enum.map_join(errors, ", ", fn {field, {msg, _opts}} -> "#{field}: #{msg}" end)

      _ ->
        "Unknown error"
    end
  end

  def toggle_include_deleted_query(query) when is_binary(query) do
    case SRQLBuilder.parse(query) do
      {:ok, builder} ->
        filters = Map.get(builder, "filters", [])
        {updated_filters, _enabled} = toggle_builder_filter(filters, "include_deleted")

        builder
        |> Map.put("filters", updated_filters)
        |> SRQLBuilder.build()

      _ ->
        fallback_toggle_include_deleted_query(query)
    end
  end

  def toggle_include_deleted_query(_), do: "in:devices include_deleted:true"

  def device_list_path(query, _limit, opts \\ []) do
    IndexPath.list_path(Keyword.put(opts, :query, query))
  end

  # Shared form builders for the bulk-edit controls. The modal opener (Selection)
  # and the handlers (BulkState) need the same field shapes, so they live here
  # rather than being duplicated per module.
  #
  # Scope is deliberately its own form. One control at the top of the modal
  # governs BOTH submits: it reports through phx-change into the modal-local
  # `bulk_target_scope`, and that is what Selection.selected_uids_for_scope/2
  # resolves targets from for the tag AND the state handler. It stays separate
  # from the toolbar's shared `select_all_matching` so cancelling the modal is a
  # no-op for the toolbar selection. While scope sat inside the state form it
  # read as if it only scoped the state changes, while the tag submit quietly
  # acted on the toolbar selection instead.
  def bulk_scope_form(scope \\ "selected") when is_binary(scope) do
    to_form(%{"scope" => scope, "stop_on_error" => "false"}, as: :bulk_scope)
  end

  def bulk_error_form do
    to_form(%{"stop_on_error" => "false"}, as: :bulk_error)
  end

  def availability_source_form do
    to_form(%{"agent_id" => "", "stop_on_error" => "false"}, as: :availability_source)
  end

  def stop_on_error?(value), do: value in [true, "true", "on", "1"]

  def on_error_mode(stop_on_error?) do
    if stop_on_error?, do: :halt, else: :continue
  end

  def assigns_on_error_mode(assigns, key \\ :bulk_stop_on_error) do
    on_error_mode(stop_on_error?(Map.get(assigns, key, false)))
  end

  def bulk_state_form(overrides \\ %{}) when is_map(overrides) do
    default_bulk_state_params()
    |> Map.merge(overrides)
    |> then(fn params -> to_form(params, as: :bulk_state) end)
  end

  def default_bulk_state_params do
    %{"service_state" => "no_change", "managed_state" => "no_change"}
  end

  def format_transaction_error(reason) when is_binary(reason), do: reason
  def format_transaction_error(reason) when is_exception(reason), do: Exception.message(reason)
  def format_transaction_error(reason), do: inspect(reason)

  @uid_write_batch 200

  @doc """
  How many device uids one write statement receives.

  The batch is the size of one database call. Callers loop until every uid
  in the selection has been applied.
  """
  def uid_write_batch, do: @uid_write_batch

  @doc """
  Apply `fun` to every uid, `uid_write_batch/0` at a time.

  `fun` returns `{:ok, count}`, `{:ok, count, extra}`, or `:ok` for a batch.
  The default is to keep going after a failed batch. Pass `on_error: :halt`
  only when the operator asked to stop at the first error.

  A finished walk is `{:ok, summary}`. A halted walk is `{:error, summary}`.
  `summary` carries `:applied`, `:failed`, `:total`, `:errors`, and `:extras`.
  """
  def each_uid_batch(uids, fun, opts \\ []) when is_list(uids) and is_function(fun, 1) do
    on_error = Keyword.get(opts, :on_error, :continue)

    empty = %{applied: 0, failed: 0, total: length(uids), errors: [], extras: []}

    uids
    |> Enum.chunk_every(@uid_write_batch)
    |> Enum.reduce_while({:ok, empty}, fn batch, {:ok, acc} ->
      case fun.(batch) do
        {:ok, count, extra} when is_integer(count) ->
          {:cont, {:ok, add_batch(acc, count, extra)}}

        {:ok, count} when is_integer(count) ->
          {:cont, {:ok, add_batch(acc, count, nil)}}

        :ok ->
          {:cont, {:ok, add_batch(acc, length(batch), nil)}}

        {:error, reason} ->
          acc = %{acc | failed: acc.failed + length(batch), errors: [reason | acc.errors]}

          if on_error == :halt do
            {:halt, {:error, acc}}
          else
            {:cont, {:ok, acc}}
          end
      end
    end)
    |> normalize_batch_summary()
  end

  def batch_failure_message({:ok, %{applied: _, failed: _, total: _, errors: _} = summary}) do
    "Updated #{summary.applied} of #{summary.total} device(s). #{summary.failed} failed: #{first_batch_error(summary.errors)}"
  end

  def batch_failure_message({:error, %{applied: _, total: _, errors: _} = summary}) do
    "Stopped after updating #{summary.applied} of #{summary.total} device(s): #{first_batch_error(summary.errors)}"
  end

  def batch_failure_message({:error, reason}), do: format_transaction_error(reason)

  defp add_batch(acc, count, nil), do: %{acc | applied: acc.applied + count}

  defp add_batch(acc, count, extra) do
    %{acc | applied: acc.applied + count, extras: [extra | acc.extras]}
  end

  defp normalize_batch_summary({status, acc}) do
    {status, %{acc | errors: Enum.reverse(acc.errors), extras: Enum.reverse(acc.extras)}}
  end

  defp first_batch_error([reason | _]), do: format_transaction_error(reason)
  defp first_batch_error(_), do: "unknown error"

  def handle_bulk_update_result(result, existing_count, requested_count) do
    case result do
      %Ash.BulkResult{status: :success} ->
        if existing_count < requested_count do
          {:error, "One or more devices were not found"}
        else
          {:ok, existing_count}
        end

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:error, format_changeset_errors(List.first(errors || []))}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, format_changeset_errors(List.first(errors || []))}
    end
  end

  defp format_single_error(%InvalidAttribute{field: field, message: msg}), do: "#{field}: #{msg}"
  defp format_single_error(%Required{field: field}), do: "#{field} is required"
  defp format_single_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_single_error(err), do: inspect(err)

  defp toggle_builder_filter(filters, field) do
    {matches, rest} = Enum.split_with(filters, fn filter -> Map.get(filter, "field") == field end)

    if matches == [] do
      {rest ++ [%{"field" => field, "op" => "equals", "value" => "true"}], true}
    else
      {rest, false}
    end
  end

  defp fallback_toggle_include_deleted_query(query) do
    if String.contains?(query, "include_deleted:true") do
      query
      |> String.replace(~r/\s*include_deleted:true\b/, "")
      |> String.trim()
    else
      query
      |> String.trim()
      |> case do
        "" -> "in:devices include_deleted:true"
        trimmed -> "#{trimmed} include_deleted:true"
      end
    end
  end
end
