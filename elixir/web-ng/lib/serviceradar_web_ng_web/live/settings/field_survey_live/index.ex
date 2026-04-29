defmodule ServiceRadarWebNGWeb.Settings.FieldSurveyLive.Index do
  @moduledoc """
  FieldSurvey dashboard playlist settings.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Spatial.FieldSurveyDashboardPlaylistEntry
  alias ServiceRadarWebNG.FieldSurveyDashboardPlaylist
  alias ServiceRadarWebNG.RBAC

  @current_path "/settings/networks/field-survey"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      {:ok,
       socket
       |> assign(:page_title, "FieldSurvey Dashboard")
       |> assign(:current_path, @current_path)
       |> assign(:entries, load_entries(scope))
       |> assign(:editing_id, nil)
       |> assign(:preview, nil)
       |> assign(:playlist_params, params_from_attrs(FieldSurveyDashboardPlaylist.defaults()))
       |> assign_form()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage FieldSurvey dashboard settings")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("validate", %{"playlist" => params}, socket) do
    {:noreply,
     socket
     |> assign(:playlist_params, merge_params(socket.assigns.playlist_params, params))
     |> assign(:preview, nil)
     |> assign_form()}
  end

  def handle_event("preview", %{"playlist" => params}, socket) do
    preview_playlist(socket, merge_params(socket.assigns.playlist_params, params))
  end

  def handle_event("preview", _params, socket) do
    preview_playlist(socket, socket.assigns.playlist_params)
  end

  def handle_event("save", %{"playlist" => params}, socket) do
    with :ok <- authorize(socket),
         merged = merge_params(socket.assigns.playlist_params, params),
         {:ok, attrs} <- attrs_from_params(merged),
         {:ok, _entry} <- save_entry(socket, attrs) do
      scope = socket.assigns.current_scope

      {:noreply,
       socket
       |> put_flash(:info, "Saved FieldSurvey dashboard playlist entry")
       |> assign(:entries, load_entries(scope))
       |> assign(:editing_id, nil)
       |> assign(:preview, nil)
       |> assign(:playlist_params, params_from_attrs(FieldSurveyDashboardPlaylist.defaults()))
       |> assign_form()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{format_error(reason)}")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    with :ok <- authorize(socket),
         {:ok, %FieldSurveyDashboardPlaylistEntry{} = entry} <-
           FieldSurveyDashboardPlaylist.get(socket.assigns.current_scope, id) do
      {:noreply,
       socket
       |> assign(:editing_id, entry.id)
       |> assign(:preview, nil)
       |> assign(:playlist_params, params_from_entry(entry))
       |> assign_form()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not load entry: #{format_error(reason)}")}
    end
  end

  def handle_event("new", _params, socket) do
    case authorize(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:editing_id, nil)
         |> assign(:preview, nil)
         |> assign(:playlist_params, params_from_attrs(FieldSurveyDashboardPlaylist.defaults()))
         |> assign_form()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with :ok <- authorize(socket),
         {:ok, %FieldSurveyDashboardPlaylistEntry{} = entry} <- FieldSurveyDashboardPlaylist.get(scope, id),
         :ok <- FieldSurveyDashboardPlaylist.delete(scope, entry) do
      {:noreply,
       socket
       |> put_flash(:info, "Deleted FieldSurvey dashboard playlist entry")
       |> assign(:entries, load_entries(scope))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{format_error(reason)}")}
    end
  end

  defp preview_playlist(socket, merged) do
    with :ok <- authorize(socket),
         {:ok, candidate} <- FieldSurveyDashboardPlaylist.preview(socket.assigns.current_scope, merged["srql_query"]) do
      {:noreply,
       socket
       |> assign(:playlist_params, merged)
       |> assign(:preview, {:ok, candidate})
       |> put_flash(:info, "Query resolves to a persisted FieldSurvey raster")
       |> assign_form()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:preview, {:error, reason})
         |> put_flash(:error, "Preview failed: #{format_error(reason)}")
         |> assign_form()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <div class="space-y-4">
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.network_nav current_path={@current_path} current_scope={@current_scope} />
        </div>

        <section class="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(420px,0.8fr)]">
          <div class="space-y-4">
            <div>
              <h1 class="text-xl font-semibold">FieldSurvey Dashboard Playlist</h1>
              <p class="text-sm text-base-content/60">
                Define SRQL-backed heatmap candidates for the dashboard card.
              </p>
            </div>

            <div class="rounded-xl border border-base-200 bg-base-100">
              <div class="flex items-center justify-between border-b border-base-200 px-4 py-3">
                <div>
                  <h2 class="text-sm font-semibold">Playlist Entries</h2>
                  <p class="text-xs text-base-content/50">
                    Entries rotate by sort order and dwell interval.
                  </p>
                </div>
                <button type="button" class="btn btn-sm" phx-click="new">
                  <.icon name="hero-plus" class="size-4" /> New
                </button>
              </div>

              <div class="divide-y divide-base-200">
                <div :if={@entries == []} class="p-4 text-sm text-base-content/60">
                  No playlist entries yet. The dashboard will use the latest floorplan-backed Wi-Fi raster fallback.
                </div>

                <div
                  :for={entry <- @entries}
                  class="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between"
                >
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class="font-medium">{entry.label}</span>
                      <span class={[
                        "badge badge-sm",
                        if(entry.enabled, do: "badge-success", else: "badge-ghost")
                      ]}>
                        {if entry.enabled, do: "enabled", else: "disabled"}
                      </span>
                      <span class="badge badge-sm badge-outline">#{entry.sort_order}</span>
                    </div>
                    <div class="mt-1 truncate font-mono text-xs text-base-content/60">
                      {entry.srql_query}
                    </div>
                    <div class="mt-1 text-xs text-base-content/50">
                      {entry.overlay_type} · {entry.display_mode} · {entry.dwell_seconds}s dwell · max age {entry.max_age_seconds}s
                    </div>
                  </div>
                  <div class="flex shrink-0 gap-2">
                    <button type="button" class="btn btn-xs" phx-click="edit" phx-value-id={entry.id}>
                      <.icon name="hero-pencil-square" class="size-4" /> Edit
                    </button>
                    <button
                      type="button"
                      class="btn btn-xs btn-error btn-outline"
                      phx-click="delete"
                      phx-value-id={entry.id}
                    >
                      <.icon name="hero-trash" class="size-4" /> Delete
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
            <.form
              :if={@playlist_form}
              for={@playlist_form}
              id="fieldsurvey-playlist-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-4"
            >
              <div>
                <h2 class="text-sm font-semibold">
                  {if @editing_id, do: "Edit Entry", else: "New Entry"}
                </h2>
                <p class="text-xs text-base-content/50">
                  Saving requires the SRQL query to resolve to at least one persisted raster.
                </p>
              </div>

              <.input field={@playlist_form[:label]} type="text" label="Label" />
              <.input field={@playlist_form[:enabled]} type="checkbox" label="Enabled" />
              <.input field={@playlist_form[:srql_query]} type="textarea" label="SRQL query" />

              <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
                <.input field={@playlist_form[:sort_order]} type="number" label="Sort order" />
                <.input field={@playlist_form[:overlay_type]} type="text" label="Overlay type" />
                <.input field={@playlist_form[:display_mode]} type="text" label="Display mode" />
                <.input
                  field={@playlist_form[:dwell_seconds]}
                  type="number"
                  min="5"
                  max="3600"
                  label="Dwell seconds"
                />
                <.input
                  field={@playlist_form[:max_age_seconds]}
                  type="number"
                  min="60"
                  max="31536000"
                  label="Max age seconds"
                />
              </div>

              <.input field={@playlist_form[:metadata]} type="textarea" label="Metadata JSON" />

              <div :if={@preview} class={preview_class(@preview)}>
                {preview_message(@preview)}
              </div>

              <div class="flex justify-end gap-2">
                <button type="button" class="btn btn-sm" phx-click="preview">
                  <.icon name="hero-magnifying-glass" class="size-4" /> Preview
                </button>
                <button type="submit" class="btn btn-sm btn-primary">
                  <.icon name="hero-check" class="size-4" /> Save
                </button>
              </div>
            </.form>
          </div>
        </section>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp load_entries(scope) do
    case FieldSurveyDashboardPlaylist.list(scope) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  defp save_entry(socket, attrs) do
    scope = socket.assigns.current_scope

    case socket.assigns.editing_id do
      nil ->
        FieldSurveyDashboardPlaylist.create(scope, attrs)

      id ->
        with {:ok, %FieldSurveyDashboardPlaylistEntry{} = entry} <- FieldSurveyDashboardPlaylist.get(scope, id) do
          FieldSurveyDashboardPlaylist.update(scope, entry, attrs)
        end
    end
  end

  defp authorize(socket) do
    if can_manage?(socket.assigns.current_scope), do: :ok, else: {:error, :not_authorized}
  end

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.networks.manage")

  defp assign_form(socket) do
    assign(socket, :playlist_form, to_form(socket.assigns.playlist_params, as: :playlist))
  end

  defp params_from_entry(%FieldSurveyDashboardPlaylistEntry{} = entry) do
    entry
    |> Map.take([
      :label,
      :srql_query,
      :enabled,
      :sort_order,
      :overlay_type,
      :display_mode,
      :dwell_seconds,
      :max_age_seconds,
      :metadata
    ])
    |> params_from_attrs()
  end

  defp params_from_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), form_value(key, value)} end)
    |> Map.update("metadata", "{}", &metadata_string/1)
  end

  defp form_value(:enabled, value), do: value
  defp form_value(_key, value) when is_integer(value), do: Integer.to_string(value)
  defp form_value(_key, value) when is_binary(value), do: value
  defp form_value(_key, value) when is_map(value), do: metadata_string(value)
  defp form_value(_key, value), do: value || ""

  defp metadata_string(value) when is_binary(value), do: value
  defp metadata_string(value) when is_map(value), do: Jason.encode!(value)
  defp metadata_string(_value), do: "{}"

  defp merge_params(current, params) when is_map(current) and is_map(params), do: Map.merge(current, params)
  defp merge_params(_current, params) when is_map(params), do: params

  defp attrs_from_params(params) do
    {:ok,
     %{
       label: params["label"],
       srql_query: params["srql_query"],
       enabled: Map.get(params, "enabled", false),
       sort_order: params["sort_order"],
       overlay_type: params["overlay_type"],
       display_mode: params["display_mode"],
       dwell_seconds: params["dwell_seconds"],
       max_age_seconds: params["max_age_seconds"],
       metadata: params["metadata"]
     }}
  end

  defp preview_class({:ok, _}), do: "rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success"
  defp preview_class({:error, _}), do: "rounded-lg border border-error/40 bg-error/10 p-3 text-sm text-error"

  defp preview_message({:ok, %{} = candidate}) do
    session_id = Map.get(candidate, "session_id", "unknown session")
    cells = Map.get(candidate, "cell_count") || safe_length(get_in(candidate, ["cells", "cells"]))
    "Preview OK: #{session_id}, #{cells} raster cells"
  end

  defp preview_message({:error, reason}), do: "Preview failed: #{format_error(reason)}"

  defp safe_length(value) when is_list(value), do: length(value)
  defp safe_length(_), do: 0

  defp format_error(:playlist_query_must_target_field_survey_rasters),
    do: "playlist queries must use in:field_survey_rasters"

  defp format_error(:no_field_survey_raster_candidate), do: "query returned no persisted raster"
  defp format_error(:not_authorized), do: "not authorized"
  defp format_error({:required, field}), do: "#{field} is required"
  defp format_error({:invalid_integer, field}), do: "#{field} must be an integer"
  defp format_error(:invalid_metadata), do: "metadata must be a JSON object"
  defp format_error(reason), do: inspect(reason)
end
