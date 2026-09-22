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
    to_form(%{"scope" => scope}, as: :bulk_scope)
  end

  def bulk_state_form(overrides \\ %{}) when is_map(overrides) do
    default_bulk_state_params()
    |> Map.merge(overrides)
    |> then(fn params -> to_form(params, as: :bulk_state) end)
  end

  def default_bulk_state_params do
    %{"service_state" => "no_change", "managed_state" => "no_change"}
  end

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
