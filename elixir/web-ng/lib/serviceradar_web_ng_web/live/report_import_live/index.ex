defmodule ServiceRadarWebNGWeb.ReportImportLive.Index do
  @moduledoc """
  Imports report definitions from a first-party release, a GitHub repository, or
  an uploaded file.

  Gated on `analytics.dashboards.create` and `analytics.dashboards.edit`, the two
  permissions the dashboard and panel resources check when the import writes.
  Every import runs under the operator's own scope, so the resource policies
  remain the authority; the gate only avoids offering a form that would fail.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.Dashboards.ReportImporter
  alias ServiceRadarWebNG.Dashboards.ReportIndex
  alias ServiceRadarWebNG.RBAC

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @current_path "/dashboards/reports/import"
  @sources ~w(first_party github upload)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "analytics.dashboards.create") and RBAC.can?(scope, "analytics.dashboards.edit") do
      release_tag = ReportIndex.running_release_tag() || ""

      socket =
        socket
        |> assign(:page_title, "Import Report")
        |> assign(:current_path, @current_path)
        |> assign(:source, "first_party")
        |> assign(:release_form, to_form(%{"release_tag" => release_tag}, as: :release))
        |> assign(:github_form, to_form(%{"repo_url" => "", "ref" => "", "path" => ""}, as: :github))
        |> assign(:catalog, nil)
        |> assign(:catalog_error, nil)
        |> assign(:catalog_loading?, false)
        |> assign(:importing, nil)
        |> assign(:result, nil)
        |> allow_upload(:definition,
          accept: ~w(.json),
          max_entries: 1,
          max_file_size: ReportImporter.max_definition_bytes(),
          auto_upload: true
        )

      {:ok, if(connected?(socket), do: load_catalog(socket, release_tag), else: socket)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to import reports.")
       |> push_navigate(to: ~p"/dashboards")}
    end
  end

  @impl true
  def handle_event("select_source", %{"source" => source}, socket) when source in @sources do
    {:noreply, assign(socket, source: source, result: nil)}
  end

  def handle_event("load_catalog", %{"release" => %{"release_tag" => release_tag}}, socket) do
    {:noreply,
     socket
     |> assign(:release_form, to_form(%{"release_tag" => release_tag}, as: :release))
     |> load_catalog(release_tag)}
  end

  def handle_event("import_first_party", %{"slug" => slug}, socket) do
    scope = socket.assigns.current_scope
    release_tag = socket.assigns.release_form.params["release_tag"]

    {:noreply,
     start_import(socket, slug, fn ->
       ReportImporter.import_first_party(slug, scope: scope, release_tag: release_tag)
     end)}
  end

  def handle_event("github_change", %{"github" => params}, socket) do
    {:noreply, assign(socket, :github_form, to_form(params, as: :github))}
  end

  def handle_event("import_github", %{"github" => params}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:github_form, to_form(params, as: :github))
     |> start_import(:github, fn -> ReportImporter.import_github(params, scope: scope) end)}
  end

  def handle_event("upload_change", _params, socket), do: {:noreply, socket}

  def handle_event("import_upload", _params, socket) do
    scope = socket.assigns.current_scope

    case consume_definition_upload(socket) do
      {:ok, name, body} ->
        {:noreply, start_import(socket, :upload, fn -> ReportImporter.import_upload(body, name, scope: scope) end)}

      {:error, message} ->
        {:noreply, assign(socket, :result, {:error, message})}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :definition, ref)}
  end

  @impl true
  def handle_async(:catalog, {:ok, {:ok, catalog}}, socket) do
    {:noreply, assign(socket, catalog: catalog, catalog_error: nil, catalog_loading?: false)}
  end

  def handle_async(:catalog, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, catalog: nil, catalog_error: reason, catalog_loading?: false)}
  end

  def handle_async(:catalog, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, catalog: nil, catalog_error: "Loading reports failed: #{inspect(reason)}", catalog_loading?: false)}
  end

  def handle_async(:import, {:ok, result}, socket) do
    socket = assign(socket, importing: nil, result: result)

    socket =
      case {result, socket.assigns.catalog} do
        {{:ok, %{dashboard: dashboard}}, %{reports: reports} = catalog} ->
          reports = Enum.map(reports, &if(&1.slug == dashboard.slug, do: %{&1 | installed?: true}, else: &1))
          assign(socket, :catalog, %{catalog | reports: reports})

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_async(:import, {:exit, reason}, socket) do
    {:noreply, assign(socket, importing: nil, result: {:error, "Import failed: #{inspect(reason)}"})}
  end

  defp load_catalog(socket, release_tag) do
    socket
    |> assign(:catalog_loading?, true)
    |> assign(:catalog_error, nil)
    |> start_async(:catalog, fn -> ReportImporter.list_first_party(release_tag: release_tag) end)
  end

  defp start_import(socket, key, fun) do
    socket
    |> assign(:importing, key)
    |> assign(:result, nil)
    |> start_async(:import, fun)
  end

  # Sobelow flags File.read! as directory traversal because it cannot see where
  # `path` comes from. consume_uploaded_entries/3 hands back a temp file Phoenix
  # created and named itself; the CONTENT is untrusted and validated downstream.
  @sobelow_skip ["Traversal.FileModule"]
  defp consume_definition_upload(socket) do
    case consume_uploaded_entries(socket, :definition, fn %{path: path}, entry ->
           {:ok, {entry.client_name, File.read!(path)}}
         end) do
      [{name, body}] -> {:ok, name, body}
      [] -> {:error, "Choose a definition file before importing"}
      _ -> {:error, "Upload exactly one definition file"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      shell={:operations}
    >
      <div class="mx-auto flex w-full max-w-5xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
        <section class="flex flex-col gap-3 border-b border-sr-line pb-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <.link
              navigate={~p"/dashboards"}
              class="text-sm font-medium text-sr-brand hover:underline"
            >
              Dashboard &amp; Report Library
            </.link>
            <h1 class="mt-1 text-2xl font-semibold tracking-tight text-sr-ink">Import Report</h1>
            <p class="mt-2 max-w-3xl text-sm text-sr-muted">
              Add an SRQL report from a ServiceRadar release, a GitHub repository, or a definition file.
              Importing never changes a report that already exists.
            </p>
          </div>
        </section>

        <nav
          class="flex gap-1 rounded-sr-control border border-sr-line bg-sr-subtle p-1"
          role="tablist"
        >
          <button
            :for={{value, label} <- source_tabs()}
            type="button"
            role="tab"
            aria-selected={to_string(@source == value)}
            phx-click="select_source"
            phx-value-source={value}
            class={[
              "flex-1 rounded-sr-control px-3 py-2 text-sm font-medium transition-colors",
              if(@source == value,
                do: "bg-sr-surface text-sr-ink shadow-sr-button",
                else: "text-sr-muted hover:text-sr-ink"
              )
            ]}
          >
            {label}
          </button>
        </nav>

        <.import_result result={@result} />

        <.ui_panel :if={@source == "first_party"} id="first-party-reports">
          <:header>
            <div>
              <h2 class="text-sm font-semibold text-sr-ink">ServiceRadar releases</h2>
              <p class="mt-1 text-xs text-sr-muted">
                Reports published in the OSS repository's report index at a release tag.
              </p>
            </div>
          </:header>

          <.form
            for={@release_form}
            id="first-party-release-form"
            phx-submit="load_catalog"
            class="flex flex-wrap items-end gap-3"
          >
            <label class="flex min-w-48 flex-1 flex-col gap-1.5">
              <span class="text-sm font-medium text-sr-ink">Release tag</span>
              <input
                class={ui_field_class(size: "sm")}
                name={@release_form[:release_tag].name}
                value={@release_form[:release_tag].value}
                placeholder="Default branch"
              />
            </label>
            <.ui_button type="submit" size="sm" variant="ghost" disabled={@catalog_loading?}>
              <.icon name="hero-arrow-path" class="size-4" /> Load reports
            </.ui_button>
          </.form>

          <p :if={@catalog_loading?} class="mt-4 text-sm text-sr-muted">Loading reports...</p>

          <div
            :if={@catalog_error}
            class="mt-4 rounded-sr-control border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-900 dark:text-amber-200"
          >
            {@catalog_error}
          </div>

          <p
            :if={(!@catalog_loading? and @catalog) && @catalog.reports == []}
            class="mt-4 text-sm text-sr-muted"
          >
            This release's report index lists no reports.
          </p>

          <ul :if={!@catalog_loading? and @catalog} class="mt-4 divide-y divide-sr-line">
            <li
              :for={report <- @catalog.reports}
              id={"first-party-report-#{report.slug}"}
              class="flex flex-col gap-3 py-3 sm:flex-row sm:items-start sm:justify-between"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-medium text-sr-ink">{report.title}</span>
                  <.ui_badge size="xs" variant="ghost">{report.slug}</.ui_badge>
                  <.ui_badge :if={report.enabled_by_default} size="xs" variant="info">
                    Enabled by default
                  </.ui_badge>
                  <.ui_badge :if={report.installed?} size="xs" variant="success">Installed</.ui_badge>
                </div>
                <p :if={report.description} class="mt-1 text-sm text-sr-muted">
                  {report.description}
                </p>
                <p :if={report.error} class="mt-1 text-sm text-red-600 dark:text-red-400">
                  {report.error}
                </p>
                <p :if={!report.error} class="mt-1 text-xs text-sr-muted">
                  {report.panel_count} {if report.panel_count == 1, do: "panel", else: "panels"}
                </p>
              </div>
              <.ui_button
                size="sm"
                variant={if report.installed?, do: "ghost", else: "primary"}
                phx-click="import_first_party"
                phx-value-slug={report.slug}
                disabled={report.installed? or not is_nil(report.error) or not is_nil(@importing)}
              >
                {if @importing == report.slug, do: "Importing...", else: "Import"}
              </.ui_button>
            </li>
          </ul>
        </.ui_panel>

        <.ui_panel :if={@source == "github"} id="github-report-import">
          <:header>
            <div>
              <h2 class="text-sm font-semibold text-sr-ink">GitHub repository</h2>
              <p class="mt-1 text-xs text-sr-muted">
                Subject to the same trusted-repository and commit-signature policy as plugin imports.
              </p>
            </div>
          </:header>

          <.form
            for={@github_form}
            id="github-report-form"
            phx-change="github_change"
            phx-submit="import_github"
            class="grid gap-4 sm:grid-cols-2"
          >
            <label class="flex flex-col gap-1.5 sm:col-span-2">
              <span class="text-sm font-medium text-sr-ink">Repository URL</span>
              <input
                class={ui_field_class(size: "sm")}
                name={@github_form[:repo_url].name}
                value={@github_form[:repo_url].value}
                placeholder="https://github.com/org/repo"
              />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-sr-ink">Ref</span>
              <input
                class={ui_field_class(size: "sm")}
                name={@github_form[:ref].name}
                value={@github_form[:ref].value}
                placeholder="Default branch"
              />
            </label>
            <label class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-sr-ink">Definition path</span>
              <input
                class={ui_field_class(size: "sm")}
                name={@github_form[:path].name}
                value={@github_form[:path].value}
                placeholder="reports/my-report.json"
              />
            </label>
            <div class="sm:col-span-2">
              <.ui_button type="submit" size="sm" variant="primary" disabled={not is_nil(@importing)}>
                {if @importing == :github, do: "Importing...", else: "Import from GitHub"}
              </.ui_button>
            </div>
          </.form>
        </.ui_panel>

        <.ui_panel :if={@source == "upload"} id="upload-report-import">
          <:header>
            <div>
              <h2 class="text-sm font-semibold text-sr-ink">Definition file</h2>
              <p class="mt-1 text-xs text-sr-muted">
                A dashboard definition JSON, such as one exported from the builder.
                Validated exactly as a definition fetched from a repository.
              </p>
            </div>
          </:header>

          <.form
            for={%{}}
            as={:upload}
            id="upload-report-form"
            phx-change="upload_change"
            phx-submit="import_upload"
            class="space-y-4"
          >
            <.live_file_input
              upload={@uploads.definition}
              class={
                ui_field_class(
                  size: "sm",
                  class:
                    "w-full file:mr-3 file:rounded-sr-control file:border-0 file:bg-sr-subtle file:px-2 file:py-1 file:text-xs file:font-semibold file:text-sr-ink"
                )
              }
            />
            <div
              :for={entry <- @uploads.definition.entries}
              class="flex items-center justify-between gap-3 text-sm text-sr-muted"
            >
              <span class="truncate">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-xs text-sr-muted hover:text-sr-ink"
              >
                Remove
              </button>
              <p
                :for={error <- upload_errors(@uploads.definition, entry)}
                class="text-sm text-red-600 dark:text-red-400"
              >
                {upload_error_message(error)}
              </p>
            </div>
            <.ui_button type="submit" size="sm" variant="primary" disabled={not is_nil(@importing)}>
              {if @importing == :upload, do: "Importing...", else: "Import file"}
            </.ui_button>
          </.form>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true

  defp import_result(%{result: nil} = assigns), do: ~H""

  defp import_result(%{result: {:ok, %{dashboard: dashboard, outcome: outcome}}} = assigns) do
    assigns = assign(assigns, dashboard: dashboard, message: outcome_message(outcome, dashboard))

    ~H"""
    <div
      id="report-import-result"
      class="flex flex-col gap-2 rounded-sr-surface border border-sr-brand/25 bg-sr-subtle p-4 text-sm text-sr-ink sm:flex-row sm:items-center sm:justify-between"
    >
      <span>{@message}</span>
      <.ui_button navigate={~p"/dashboard/#{@dashboard.dashboard_ref}"} size="sm" variant="ghost">
        <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open
      </.ui_button>
    </div>
    """
  end

  defp import_result(%{result: {:error, message}} = assigns) do
    assigns = assign(assigns, :message, message)

    ~H"""
    <div
      id="report-import-result"
      class="rounded-sr-surface border border-red-500/30 bg-red-500/10 p-4 text-sm text-red-800 dark:text-red-200"
    >
      {@message}
    </div>
    """
  end

  defp outcome_message(:created, dashboard), do: "Imported \"#{dashboard.title}\"."

  defp outcome_message(:completed, dashboard),
    do: "\"#{dashboard.title}\" existed without panels; its panels have been created."

  defp outcome_message(:kept, dashboard),
    do:
      "A dashboard with slug \"#{dashboard.slug}\" already exists and was left unchanged. " <>
        "Importing never overwrites an existing dashboard."

  defp source_tabs, do: [{"first_party", "ServiceRadar release"}, {"github", "GitHub"}, {"upload", "Upload"}]

  defp upload_error_message(:too_large), do: "File is larger than #{div(ReportImporter.max_definition_bytes(), 1024)} KiB"

  defp upload_error_message(:not_accepted), do: "Only .json definition files are accepted"
  defp upload_error_message(:too_many_files), do: "Upload one file at a time"
  defp upload_error_message(error), do: inspect(error)
end
