defmodule ServiceRadarWebNGWeb.Settings.AgentsLive.Releases do
  @moduledoc """
  LiveView for publishing agent releases and managing rollout execution.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @inflight_statuses [:dispatched, :downloading, :verifying, :staged, :restarting]
  @artifact_formats [
    {"Binary", "binary"},
    {"tar.gz Archive", "tar.gz"}
  ]
  @cohort_options [
    {"Connected Agents", "connected"},
    {"Custom Agent IDs", "custom"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, "settings.edge.manage") do
      {:ok,
       socket
       |> assign(:page_title, "Agent Releases")
       |> assign(:current_path, "/settings/agents/releases")
       |> assign(:artifact_formats, @artifact_formats)
       |> assign(:cohort_options, @cohort_options)
       |> assign(:release_form, release_form())
       |> assign(:rollout_form, rollout_form())
       |> assign(:releases, [])
       |> assign(:rollouts, [])
       |> assign(:connected_agents, [])
       |> assign(:rollout_summaries, %{})
       |> assign(:rollout_prefill_count, 0)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to agent release management")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, load_page_data(socket, params)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_page_data(socket)}
  end

  def handle_event("publish_release", %{"release" => params}, socket) do
    scope = socket.assigns.current_scope
    attrs = build_release_attrs(params)

    case AgentReleaseManager.publish_release(attrs, scope: scope) do
      {:ok, _release} ->
        {:noreply,
         socket
         |> put_flash(:info, "Published agent release #{attrs.version}")
         |> load_page_data()
         |> assign(:release_form, release_form())}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Publish failed: #{format_error(reason)}")
         |> assign(:release_form, release_form(params))}
    end
  end

  def handle_event("create_rollout", %{"rollout" => params}, socket) do
    scope = socket.assigns.current_scope
    agent_ids = rollout_agent_ids(params, socket.assigns.connected_agents)

    cond do
      blank?(params["version"]) ->
        {:noreply,
         socket
         |> put_flash(:error, "Select a release version for the rollout")
         |> assign(:rollout_form, rollout_form(params, socket.assigns.releases))}

      agent_ids == [] ->
        {:noreply,
         socket
         |> put_flash(:error, "Select at least one agent for the rollout")
         |> assign(:rollout_form, rollout_form(params, socket.assigns.releases))}

      true ->
        attrs = %{
          version: String.trim(params["version"]),
          agent_ids: agent_ids,
          batch_size: params["batch_size"],
          batch_delay_seconds: params["batch_delay_seconds"],
          notes: presence(params["notes"])
        }

        case AgentReleaseManager.create_rollout(attrs, scope: scope) do
          {:ok, rollout} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Created rollout for #{rollout.desired_version} targeting #{length(agent_ids)} agents"
             )
             |> load_page_data()
             |> assign(:rollout_form, rollout_form(%{}, socket.assigns.releases))}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Rollout failed: #{format_error(reason)}")
             |> assign(:rollout_form, rollout_form(params, socket.assigns.releases))}
        end
    end
  end

  def handle_event("pause_rollout", %{"id" => rollout_id}, socket) do
    {:noreply, mutate_rollout(socket, rollout_id, :pause)}
  end

  def handle_event("resume_rollout", %{"id" => rollout_id}, socket) do
    {:noreply, mutate_rollout(socket, rollout_id, :resume)}
  end

  def handle_event("cancel_rollout", %{"id" => rollout_id}, socket) do
    {:noreply, mutate_rollout(socket, rollout_id, :cancel)}
  end

  defp mutate_rollout(socket, rollout_id, action) do
    scope = socket.assigns.current_scope

    result =
      case action do
        :pause -> AgentReleaseManager.pause_rollout(rollout_id, scope: scope)
        :resume -> AgentReleaseManager.resume_rollout(rollout_id, scope: scope)
        :cancel -> AgentReleaseManager.cancel_rollout(rollout_id, scope: scope)
      end

    case result do
      {:ok, rollout} ->
        socket
        |> put_flash(:info, rollout_action_message(action, rollout.desired_version))
        |> load_page_data()

      {:error, reason} ->
        put_flash(socket, :error, "Rollout update failed: #{format_error(reason)}")
    end
  end

  defp load_page_data(socket, params \\ %{}) do
    scope = socket.assigns.current_scope
    releases = list_releases(scope)
    rollouts = list_rollouts(scope)
    connected_agents = list_connected_agents(scope)
    rollout_summaries = list_rollout_summaries(rollouts, scope)
    prefill = rollout_prefill_params(params)
    prefill_count = prefill_agent_count(prefill)

    socket
    |> assign(:releases, releases)
    |> assign(:rollouts, rollouts)
    |> assign(:connected_agents, connected_agents)
    |> assign(:rollout_summaries, rollout_summaries)
    |> assign(:rollout_prefill_count, prefill_count)
    |> assign(:release_form, normalize_release_form(socket.assigns.release_form))
    |> assign(
      :rollout_form,
      if(prefill == %{}, do: normalize_rollout_form(socket.assigns.rollout_form, releases), else: rollout_form(prefill, releases))
    )
  end

  defp list_releases(scope) do
    AgentRelease
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(published_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(25)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, releases} -> releases
      {:error, _} -> []
    end
  end

  defp list_rollouts(scope) do
    AgentReleaseRollout
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.load(:release)
    |> Ash.Query.limit(20)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rollouts} -> rollouts
      {:error, _} -> []
    end
  end

  defp list_connected_agents(scope) do
    Agent
    |> Ash.Query.for_read(:connected, %{})
    |> Ash.Query.sort(uid: :asc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  defp list_rollout_summaries([], _scope), do: %{}

  defp list_rollout_summaries(rollouts, scope) do
    rollout_ids = Enum.map(rollouts, & &1.id)

    targets =
      AgentReleaseTarget
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(rollout_id in ^rollout_ids)
      |> Ash.read(scope: scope)
      |> case do
        {:ok, targets} -> targets
        {:error, _} -> []
      end

    targets
    |> Enum.group_by(& &1.rollout_id)
    |> Map.new(fn {rollout_id, grouped_targets} ->
      {rollout_id, summarize_targets(grouped_targets)}
    end)
  end

  defp summarize_targets(targets) do
    Enum.reduce(targets, %{total: 0, healthy: 0, failed: 0, rolled_back: 0, inflight: 0}, fn target, acc ->
      acc
      |> Map.update!(:total, &(&1 + 1))
      |> increment_summary(target.status)
    end)
  end

  defp increment_summary(summary, status) when status in @inflight_statuses,
    do: Map.update!(summary, :inflight, &(&1 + 1))

  defp increment_summary(summary, :healthy), do: Map.update!(summary, :healthy, &(&1 + 1))
  defp increment_summary(summary, :failed), do: Map.update!(summary, :failed, &(&1 + 1))

  defp increment_summary(summary, :rolled_back),
    do: Map.update!(summary, :rolled_back, &(&1 + 1))

  defp increment_summary(summary, _status), do: summary

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <.settings_nav current_path={@current_path} current_scope={@current_scope} />
        <.agents_nav current_path={@current_path} current_scope={@current_scope} />
        <.edge_nav current_path={@current_path} current_scope={@current_scope} />

        <div class="space-y-6">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-base-content">Agent Releases</h1>
              <p class="text-sm text-base-content/60">
                Publish signed agent releases and orchestrate fleet rollouts from the existing control plane.
              </p>
            </div>
            <.ui_button variant="ghost" size="sm" phx-click="refresh">
              <.icon name="hero-arrow-path" class="size-4" /> Refresh
            </.ui_button>
          </div>

          <div class="grid gap-6 xl:grid-cols-2">
            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Publish Release</div>
              </:header>
              <div class="p-6">
                <.form
                  for={@release_form}
                  id="publish-release-form"
                  phx-submit="publish_release"
                  class="space-y-4"
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <.input field={@release_form[:version]} label="Version" placeholder="1.2.3" required />
                    <.input
                      field={@release_form[:signature]}
                      label="Manifest Signature"
                      placeholder="base64 or hex Ed25519 signature"
                      required
                    />
                    <.input
                      field={@release_form[:artifact_url]}
                      label="Artifact URL"
                      placeholder="https://releases.example/serviceradar-agent.tar.gz"
                      class="md:col-span-2"
                      required
                    />
                    <.input
                      field={@release_form[:artifact_sha256]}
                      label="Artifact SHA256"
                      placeholder="64-char sha256 digest"
                      class="md:col-span-2"
                      required
                    />
                    <.input
                      field={@release_form[:artifact_format]}
                      type="select"
                      label="Artifact Format"
                      options={@artifact_formats}
                    />
                    <.input
                      field={@release_form[:entrypoint]}
                      label="Entrypoint"
                      placeholder="serviceradar-agent"
                    />
                    <.input field={@release_form[:os]} label="OS" placeholder="linux" />
                    <.input field={@release_form[:arch]} label="Arch" placeholder="amd64" />
                  </div>

                  <.input
                    field={@release_form[:release_notes]}
                    type="textarea"
                    label="Release Notes"
                    placeholder="What changed in this build?"
                  />

                  <div class="flex justify-end">
                    <.ui_button type="submit" variant="primary" size="sm">
                      <.icon name="hero-arrow-up-tray" class="size-4" /> Publish Release
                    </.ui_button>
                  </div>
                </.form>
              </div>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Create Rollout</div>
              </:header>
              <div class="p-6 space-y-4">
                <div class="rounded-lg bg-base-200/40 px-4 py-3 text-sm text-base-content/70">
                  Connected agents available now:
                  <span class="font-semibold text-base-content">{length(@connected_agents)}</span>
                </div>

                <div
                  :if={@rollout_prefill_count > 0}
                  class="rounded-lg border border-primary/20 bg-primary/10 px-4 py-3 text-sm text-base-content/80"
                >
                  Prefilled {@rollout_prefill_count} visible agents from the inventory view.
                </div>

                <.form
                  for={@rollout_form}
                  id="create-rollout-form"
                  phx-submit="create_rollout"
                  class="space-y-4"
                >
                  <div class="grid gap-4 md:grid-cols-2">
                    <.input
                      field={@rollout_form[:version]}
                      type="select"
                      label="Release Version"
                      options={release_options(@releases)}
                      prompt="Select a published release"
                      required
                    />
                    <.input
                      field={@rollout_form[:cohort]}
                      type="select"
                      label="Target Cohort"
                      options={@cohort_options}
                    />
                    <.input field={@rollout_form[:batch_size]} type="number" label="Batch Size" min="1" />
                    <.input
                      field={@rollout_form[:batch_delay_seconds]}
                      type="number"
                      label="Batch Delay Seconds"
                      min="0"
                    />
                  </div>

                  <.input
                    field={@rollout_form[:agent_ids]}
                    type="textarea"
                    label="Custom Agent IDs"
                    placeholder="agent-1, agent-2 or one per line"
                  />

                  <.input
                    field={@rollout_form[:notes]}
                    type="textarea"
                    label="Notes"
                    placeholder="Change window, cohort rationale, rollback notes"
                  />

                  <div class="flex justify-end">
                    <.ui_button type="submit" variant="primary" size="sm" disabled={@releases == []}>
                      <.icon name="hero-play" class="size-4" /> Start Rollout
                    </.ui_button>
                  </div>
                </.form>
              </div>
            </.ui_panel>
          </div>

          <div class="grid gap-6 2xl:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)]">
            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Published Releases</div>
              </:header>
              <div class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr>
                      <th>Version</th>
                      <th>Published</th>
                      <th>Artifacts</th>
                      <th>Notes</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@releases == []}>
                      <td colspan="4" class="py-8 text-center text-sm text-base-content/60">
                        No releases have been published yet.
                      </td>
                    </tr>
                    <%= for release <- @releases do %>
                      <tr>
                        <td class="font-mono text-xs">{release.version}</td>
                        <td class="font-mono text-xs">{format_datetime(release.published_at || release.inserted_at)}</td>
                        <td class="text-xs">{artifact_count(release.manifest)}</td>
                        <td class="max-w-sm truncate text-xs" title={release.release_notes || "—"}>
                          {release.release_notes || "—"}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </.ui_panel>

            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Recent Rollouts</div>
              </:header>
              <div class="overflow-x-auto">
                <table class="table table-sm w-full">
                  <thead>
                    <tr>
                      <th>Version</th>
                      <th>Status</th>
                      <th>Cohort</th>
                      <th>Progress</th>
                      <th>Updated</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@rollouts == []}>
                      <td colspan="6" class="py-8 text-center text-sm text-base-content/60">
                        No rollouts have been created yet.
                      </td>
                    </tr>
                    <%= for rollout <- @rollouts do %>
                      <% summary = Map.get(@rollout_summaries, rollout.id, empty_rollout_summary()) %>
                      <tr>
                        <td>
                          <div class="flex flex-col gap-1">
                            <span class="font-mono text-xs">{rollout_version(rollout)}</span>
                            <span class="text-[11px] text-base-content/50">{rollout.created_by || "system"}</span>
                          </div>
                        </td>
                        <td><.rollout_status_badge status={rollout.status} /></td>
                        <td class="text-xs">{length(rollout.cohort_agent_ids || [])} agents</td>
                        <td class="text-xs">{rollout_progress_text(summary)}</td>
                        <td class="font-mono text-xs">{format_datetime(rollout.last_dispatch_at || rollout.updated_at || rollout.inserted_at)}</td>
                        <td>
                          <div class="flex flex-wrap gap-2">
                            <button
                              :if={rollout.status == :active}
                              type="button"
                              phx-click="pause_rollout"
                              phx-value-id={rollout.id}
                              class="btn btn-xs btn-ghost"
                            >
                              Pause
                            </button>
                            <button
                              :if={rollout.status == :paused}
                              type="button"
                              phx-click="resume_rollout"
                              phx-value-id={rollout.id}
                              class="btn btn-xs btn-ghost"
                            >
                              Resume
                            </button>
                            <button
                              :if={rollout.status in [:active, :paused]}
                              type="button"
                              phx-click="cancel_rollout"
                              phx-value-id={rollout.id}
                              data-confirm="Cancel this rollout?"
                              class="btn btn-xs btn-error btn-outline"
                            >
                              Cancel
                            </button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </.ui_panel>
          </div>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :status, :atom, required: true

  defp rollout_status_badge(assigns) do
    {label, variant} =
      case assigns.status do
        :active -> {"Active", "success"}
        :paused -> {"Paused", "warning"}
        :completed -> {"Completed", "info"}
        :canceled -> {"Canceled", "ghost"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="sm">{@label}</.ui_badge>
    """
  end

  defp release_form(params \\ %{}) do
    to_form(
      %{
        "version" => Map.get(params, "version", ""),
        "signature" => Map.get(params, "signature", ""),
        "artifact_url" => Map.get(params, "artifact_url", ""),
        "artifact_sha256" => Map.get(params, "artifact_sha256", ""),
        "artifact_format" => Map.get(params, "artifact_format", "tar.gz"),
        "entrypoint" => Map.get(params, "entrypoint", "serviceradar-agent"),
        "os" => Map.get(params, "os", "linux"),
        "arch" => Map.get(params, "arch", "amd64"),
        "release_notes" => Map.get(params, "release_notes", "")
      },
      as: :release
    )
  end

  defp rollout_form(params \\ %{}, releases \\ []) do
    default_version =
      Map.get(params, "version") ||
        releases
        |> List.first()
        |> case do
          nil -> ""
          release -> release.version
        end

    to_form(
      %{
        "version" => default_version,
        "cohort" => Map.get(params, "cohort", "connected"),
        "agent_ids" => Map.get(params, "agent_ids", ""),
        "batch_size" => Map.get(params, "batch_size", "10"),
        "batch_delay_seconds" => Map.get(params, "batch_delay_seconds", "60"),
        "notes" => Map.get(params, "notes", "")
      },
      as: :rollout
    )
  end

  defp normalize_release_form(%Phoenix.HTML.Form{} = form), do: form
  defp normalize_release_form(_other), do: release_form()

  defp normalize_rollout_form(%Phoenix.HTML.Form{} = form, releases) do
    params = form.params || %{}
    rollout_form(params, releases)
  end

  defp normalize_rollout_form(_other, releases), do: rollout_form(%{}, releases)

  defp rollout_prefill_params(params) when is_map(params) do
    %{
      "version" => presence(Map.get(params, "version")),
      "cohort" => presence(Map.get(params, "cohort")),
      "agent_ids" => normalize_prefill_agent_ids(Map.get(params, "agent_ids")),
      "batch_size" => presence(Map.get(params, "batch_size")),
      "batch_delay_seconds" => presence(Map.get(params, "batch_delay_seconds")),
      "notes" => presence(Map.get(params, "notes"))
    }
    |> compact_map()
  end

  defp rollout_prefill_params(_params), do: %{}

  defp normalize_prefill_agent_ids(value) do
    value
    |> to_string()
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.uniq()
    |> Enum.join("\n")
    |> presence()
  end

  defp prefill_agent_count(prefill) do
    prefill
    |> Map.get("agent_ids", "")
    |> String.split(~r/[\s,]+/, trim: true)
    |> length()
  end

  defp build_release_attrs(params) do
    version = String.trim(params["version"] || "")

    artifact =
      %{
        "url" => presence(params["artifact_url"]),
        "sha256" => presence(params["artifact_sha256"]),
        "os" => presence(params["os"]),
        "arch" => presence(params["arch"]),
        "format" => presence(params["artifact_format"]),
        "entrypoint" => presence(params["entrypoint"])
      }
      |> compact_map()

    %{
      version: version,
      signature: presence(params["signature"]),
      release_notes: presence(params["release_notes"]),
      manifest: %{
        "version" => version,
        "artifacts" => [artifact]
      }
    }
  end

  defp rollout_agent_ids(params, connected_agents) do
    case params["cohort"] do
      "custom" ->
        params["agent_ids"]
        |> to_string()
        |> String.split(~r/[\s,]+/, trim: true)
        |> Enum.uniq()

      _ ->
        Enum.map(connected_agents, & &1.uid)
    end
  end

  defp rollout_action_message(:pause, version), do: "Paused rollout for #{version}"
  defp rollout_action_message(:resume, version), do: "Resumed rollout for #{version}"
  defp rollout_action_message(:cancel, version), do: "Canceled rollout for #{version}"

  defp release_options(releases) do
    Enum.map(releases, fn release -> {release.version, release.version} end)
  end

  defp artifact_count(%{"artifacts" => artifacts}) when is_list(artifacts), do: length(artifacts)
  defp artifact_count(%{artifacts: artifacts}) when is_list(artifacts), do: length(artifacts)
  defp artifact_count(_manifest), do: 0

  defp rollout_progress_text(summary) do
    [
      "#{summary.healthy}/#{summary.total} healthy",
      summary.inflight > 0 && "#{summary.inflight} inflight",
      summary.failed > 0 && "#{summary.failed} failed",
      summary.rolled_back > 0 && "#{summary.rolled_back} rolled back"
    ]
    |> Enum.reject(&(&1 in [false, nil]))
    |> Enum.join(" · ")
  end

  defp empty_rollout_summary do
    %{total: 0, healthy: 0, failed: 0, rolled_back: 0, inflight: 0}
  end

  defp rollout_version(%{desired_version: version}) when is_binary(version) and version != "",
    do: version

  defp rollout_version(%{release: %{version: version}}) when is_binary(version), do: version
  defp rollout_version(_rollout), do: "—"

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(other), do: to_string(other)

  defp format_error(%{errors: errors}) when is_list(errors), do: Enum.map_join(errors, "; ", &format_error/1)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp presence(value) do
    case value do
      nil -> nil
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        value
    end
  end

  defp blank?(value), do: is_nil(presence(value))
end
