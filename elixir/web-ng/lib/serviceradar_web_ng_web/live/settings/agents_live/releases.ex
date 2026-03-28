defmodule ServiceRadarWebNGWeb.Settings.AgentsLive.Releases do
  @moduledoc """
  LiveView for publishing agent releases and managing rollout execution.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias Phoenix.HTML.Form
  alias ServiceRadar.AgentCommands.PubSub, as: AgentCommandPubSub
  alias ServiceRadar.Edge.AgentRelease
  alias ServiceRadar.Edge.AgentReleaseManager
  alias ServiceRadar.Edge.AgentReleaseRollout
  alias ServiceRadar.Edge.AgentReleaseTarget
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadarWebNG.RBAC

  require Ash.Query

  @release_command_type "agent.update_release"
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

    if connected?(socket) do
      AgentCommandPubSub.subscribe()
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:registrations")
    end

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
       |> assign(:rollout_targets, %{})
       |> assign(:rollout_prefill_count, 0)
       |> assign(:rollout_prefill_source, nil)
       |> assign(:rollout_preview, empty_rollout_preview())
       |> assign(:refresh_timer, nil)}
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

  def handle_event("use_release", %{"version" => version}, socket) do
    params =
      socket.assigns.rollout_form.params
      |> Map.new()
      |> Map.put("version", version)

    {:noreply, assign_rollout_form_and_preview(socket, params)}
  end

  def handle_event("preview_rollout", %{"rollout" => params}, socket) do
    {:noreply, assign_rollout_form_and_preview(socket, params)}
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
         |> assign_rollout_form_and_preview(params)}

      agent_ids == [] ->
        {:noreply,
         socket
         |> put_flash(:error, "Select at least one agent for the rollout")
         |> assign_rollout_form_and_preview(params)}

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
             |> assign_rollout_form_and_preview(params)}
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

  @impl true
  def handle_info({:command_ack, data}, socket), do: {:noreply, maybe_refresh_for_release_command(socket, data)}

  def handle_info({:command_progress, data}, socket), do: {:noreply, maybe_refresh_for_release_command(socket, data)}

  def handle_info({:command_result, data}, socket), do: {:noreply, maybe_refresh_for_release_command(socket, data)}

  def handle_info({:agent_registered, _metadata}, socket), do: {:noreply, schedule_refresh(socket)}
  def handle_info({:agent_disconnected, _agent_id}, socket), do: {:noreply, schedule_refresh(socket)}
  def handle_info({:agent_status_changed, _agent_id, _status}, socket), do: {:noreply, schedule_refresh(socket)}

  def handle_info(:refresh_releases_page, socket) do
    {:noreply,
     socket
     |> assign(:refresh_timer, nil)
     |> load_page_data()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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
    {rollout_summaries, rollout_targets} = list_rollout_data(rollouts, scope)
    prefill = rollout_prefill_params(params)
    prefill_count = prefill_agent_count(prefill)

    rollout_form =
      if(prefill == %{},
        do: normalize_rollout_form(socket.assigns.rollout_form, releases),
        else: rollout_form(prefill, releases)
      )

    rollout_preview = build_rollout_preview(rollout_form.params || %{}, releases, connected_agents, scope)

    socket
    |> assign(:releases, releases)
    |> assign(:rollouts, rollouts)
    |> assign(:connected_agents, connected_agents)
    |> assign(:rollout_summaries, rollout_summaries)
    |> assign(:rollout_targets, rollout_targets)
    |> assign(:rollout_prefill_count, prefill_count)
    |> assign(:rollout_prefill_source, Map.get(params, "source"))
    |> assign(:release_form, normalize_release_form(socket.assigns.release_form))
    |> assign(:rollout_form, rollout_form)
    |> assign(:rollout_preview, rollout_preview)
  end

  defp assign_rollout_form_and_preview(socket, params) do
    rollout_form = rollout_form(params, socket.assigns.releases)

    rollout_preview =
      build_rollout_preview(
        rollout_form.params || %{},
        socket.assigns.releases,
        socket.assigns.connected_agents,
        socket.assigns.current_scope
      )

    socket
    |> assign(:rollout_form, rollout_form)
    |> assign(:rollout_preview, rollout_preview)
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

  defp list_rollout_data([], _scope), do: {%{}, %{}}

  defp list_rollout_data(rollouts, scope) do
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

    agents_by_uid = targets |> list_rollout_agents(scope) |> Map.new(&{&1.uid, &1})
    grouped_targets = Enum.group_by(targets, & &1.rollout_id)

    summaries =
      Map.new(grouped_targets, fn {rollout_id, rollout_targets} ->
        {rollout_id, summarize_targets(rollout_targets)}
      end)

    target_details =
      Map.new(grouped_targets, fn {rollout_id, rollout_targets} ->
        {rollout_id,
         rollout_targets
         |> Enum.sort_by(&{&1.inserted_at, &1.agent_id}, {:desc, :asc})
         |> Enum.take(8)
         |> Enum.map(&rollout_target_detail(&1, agents_by_uid))}
      end)

    {summaries, target_details}
  end

  defp list_rollout_agents([], _scope), do: []

  defp list_rollout_agents(targets, scope) do
    agent_ids =
      targets
      |> Enum.map(& &1.agent_id)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    Agent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  defp rollout_target_detail(target, agents_by_uid) do
    %{
      target: target,
      platform_label: agents_by_uid |> Map.get(target.agent_id) |> agent_platform_label() |> presence()
    }
  end

  defp summarize_targets(targets) do
    Enum.reduce(targets, empty_rollout_summary(), fn target, acc ->
      acc
      |> Map.update!(:total, &(&1 + 1))
      |> increment_summary(target.status)
    end)
  end

  defp increment_summary(summary, status) do
    summary
    |> increment_state_count(status)
    |> increment_summary_bucket(status)
  end

  defp increment_summary_bucket(summary, status) when status in @inflight_statuses,
    do: Map.update!(summary, :inflight, &(&1 + 1))

  defp increment_summary_bucket(summary, :healthy), do: Map.update!(summary, :healthy, &(&1 + 1))
  defp increment_summary_bucket(summary, :failed), do: Map.update!(summary, :failed, &(&1 + 1))

  defp increment_summary_bucket(summary, :rolled_back), do: Map.update!(summary, :rolled_back, &(&1 + 1))

  defp increment_summary_bucket(summary, _status), do: summary

  defp increment_state_count(summary, status) when is_atom(status) do
    Map.update!(summary, :state_counts, fn state_counts ->
      Map.update(state_counts, status, 1, &(&1 + 1))
    end)
  end

  defp increment_state_count(summary, _status), do: summary

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
                    <.input
                      field={@release_form[:version]}
                      label="Version"
                      placeholder="1.2.3"
                      required
                    />
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
                  {rollout_prefill_message(@rollout_prefill_count, @rollout_prefill_source)}
                </div>

                <.form
                  for={@rollout_form}
                  id="create-rollout-form"
                  phx-change="preview_rollout"
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
                    <.input
                      field={@rollout_form[:batch_size]}
                      type="number"
                      label="Batch Size"
                      min="1"
                    />
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

                  <div
                    :if={show_rollout_preview?(@rollout_preview)}
                    id="rollout-compatibility-preview"
                    class="rounded-lg border border-base-300 bg-base-200/30 px-4 py-3 text-sm"
                  >
                    <div class="flex flex-wrap items-center justify-between gap-3">
                      <div class="font-semibold text-base-content">Compatibility Preview</div>
                      <div class="text-xs text-base-content/60">
                        {rollout_preview_scope_text(@rollout_preview)}
                      </div>
                    </div>

                    <div class="mt-3 flex flex-wrap gap-2">
                      <.ui_badge variant="ghost" size="xs">
                        {@rollout_preview.selected_count} selected
                      </.ui_badge>
                      <.ui_badge variant="success" size="xs">
                        {@rollout_preview.compatible_count} compatible
                      </.ui_badge>
                      <.ui_badge
                        :if={@rollout_preview.unsupported_count > 0}
                        variant="error"
                        size="xs"
                      >
                        {@rollout_preview.unsupported_count} unsupported
                      </.ui_badge>
                      <.ui_badge
                        :if={@rollout_preview.unknown_count > 0}
                        variant="warning"
                        size="xs"
                      >
                        {@rollout_preview.unknown_count} unresolved
                      </.ui_badge>
                    </div>

                    <div :if={@rollout_preview.release_missing?} class="mt-3 text-[11px] text-warning">
                      Select a published release to preview platform compatibility.
                    </div>

                    <div
                      :if={not is_nil(rollout_preview_block_message(@rollout_preview))}
                      class="mt-3 text-[11px] font-medium text-warning"
                    >
                      {rollout_preview_block_message(@rollout_preview)}
                    </div>

                    <div :if={@rollout_preview.supported_platforms != []} class="mt-3 space-y-2">
                      <div class="text-[11px] uppercase tracking-wider text-base-content/50">
                        Release Supports
                      </div>
                      <div class="flex flex-wrap gap-1">
                        <%= for platform <- @rollout_preview.supported_platforms do %>
                          <.ui_badge variant="ghost" size="xs">{platform}</.ui_badge>
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={@rollout_preview.unsupported_agents != []}
                      class="mt-3 space-y-2 text-[11px]"
                    >
                      <div class="uppercase tracking-wider text-error">Unsupported Targets</div>
                      <div class="flex flex-wrap gap-1">
                        <%= for agent <- @rollout_preview.unsupported_agents do %>
                          <span class="rounded-full bg-error/10 px-2 py-1 font-mono text-error">
                            {agent.agent_id} ({agent.platform_label})
                          </span>
                        <% end %>
                      </div>
                    </div>

                    <div
                      :if={@rollout_preview.unknown_agent_ids != []}
                      class="mt-3 space-y-2 text-[11px]"
                    >
                      <div class="uppercase tracking-wider text-warning">Unresolved Agent IDs</div>
                      <div class="flex flex-wrap gap-1">
                        <%= for agent_id <- @rollout_preview.unknown_agent_ids do %>
                          <span class="rounded-full bg-warning/10 px-2 py-1 font-mono text-warning">
                            {agent_id}
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <div class="flex justify-end">
                    <.ui_button
                      type="submit"
                      variant="primary"
                      size="sm"
                      disabled={rollout_submit_disabled?(@releases, @rollout_preview)}
                    >
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
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={@releases == []}>
                      <td colspan="5" class="py-8 text-center text-sm text-base-content/60">
                        No releases have been published yet.
                      </td>
                    </tr>
                    <%= for {release, index} <- Enum.with_index(@releases) do %>
                      <% platforms = artifact_platforms(release.manifest) %>
                      <tr>
                        <td class="font-mono text-xs">
                          <div class="flex items-center gap-2">
                            <span>{release.version}</span>
                            <span :if={index == 0} class="badge badge-success badge-xs">Latest</span>
                          </div>
                        </td>
                        <td class="font-mono text-xs">
                          {format_datetime(release.published_at || release.inserted_at)}
                        </td>
                        <td class="text-xs">
                          <div class="flex flex-col gap-2">
                            <span>{artifact_count(release.manifest)} artifacts</span>
                            <div :if={platforms != []} class="flex flex-wrap gap-1">
                              <%= for platform <- platforms do %>
                                <.ui_badge variant="ghost" size="xs">{platform}</.ui_badge>
                              <% end %>
                            </div>
                          </div>
                        </td>
                        <td class="max-w-sm truncate text-xs" title={release.release_notes || "—"}>
                          {release.release_notes || "—"}
                        </td>
                        <td>
                          <button
                            id={"use-release-#{release.version}"}
                            type="button"
                            phx-click="use_release"
                            phx-value-version={release.version}
                            class="btn btn-xs btn-ghost"
                          >
                            Use for Rollout
                          </button>
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
                      <% rollout_target_details = Map.get(@rollout_targets, rollout.id, []) %>
                      <tr>
                        <td>
                          <div class="flex flex-col gap-1">
                            <span class="font-mono text-xs">{rollout_version(rollout)}</span>
                            <span class="text-[11px] text-base-content/50">
                              {rollout.created_by || "system"}
                            </span>
                          </div>
                        </td>
                        <td><.rollout_status_badge status={rollout.status} /></td>
                        <td class="text-xs">{length(rollout.cohort_agent_ids || [])} agents</td>
                        <td class="text-xs">
                          <div class="flex flex-col gap-2">
                            <span>{rollout_progress_text(summary)}</span>
                            <div
                              :if={rollout_progress_badges(summary) != []}
                              class="flex flex-wrap gap-1"
                            >
                              <%= for %{label: label, variant: variant} <- rollout_progress_badges(summary) do %>
                                <.ui_badge variant={variant} size="xs">{label}</.ui_badge>
                              <% end %>
                            </div>
                          </div>
                        </td>
                        <td class="font-mono text-xs">
                          {format_datetime(
                            rollout.last_dispatch_at || rollout.updated_at || rollout.inserted_at
                          )}
                        </td>
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
                      <tr :if={rollout_target_details != []}>
                        <td colspan="6" class="bg-base-200/20">
                          <div class="flex flex-col gap-3 px-2 py-3">
                            <div class="text-[11px] font-semibold uppercase tracking-wider text-base-content/50">
                              Recent Target States
                            </div>
                            <div class="grid gap-2 lg:grid-cols-2">
                              <%= for detail <- rollout_target_details do %>
                                <% target = detail.target %>
                                <div class="rounded-lg border border-base-200 bg-base-100 px-3 py-2">
                                  <div class="flex items-center justify-between gap-3">
                                    <div class="flex flex-col gap-1">
                                      <span class="font-mono text-xs">{target.agent_id}</span>
                                      <span
                                        :if={display_target_platform(detail) not in [nil, ""]}
                                        class="text-[11px] text-base-content/50"
                                      >
                                        {display_target_platform(detail)}
                                      </span>
                                    </div>
                                    <.target_status_badge status={target.status} />
                                  </div>
                                  <div class="mt-1 text-[11px] text-base-content/60">
                                    {target_progress_summary(target)}
                                  </div>
                                  <div
                                    :if={platform_mismatch_error?(target.last_error)}
                                    class="mt-2 flex flex-wrap gap-1"
                                  >
                                    <.ui_badge variant="error" size="xs">
                                      Unsupported Platform
                                    </.ui_badge>
                                  </div>
                                  <div
                                    :if={target.last_error not in [nil, ""]}
                                    class="mt-1 text-[11px] text-error"
                                    title={target.last_error}
                                  >
                                    {target.last_error}
                                  </div>
                                </div>
                              <% end %>
                            </div>
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

  attr :status, :atom, required: true

  defp target_status_badge(assigns) do
    {label, variant} =
      case assigns.status do
        :pending -> {"Pending", "ghost"}
        :dispatched -> {"Dispatched", "info"}
        :downloading -> {"Downloading", "info"}
        :verifying -> {"Verifying", "info"}
        :staged -> {"Staged", "warning"}
        :restarting -> {"Restarting", "warning"}
        :healthy -> {"Healthy", "success"}
        :failed -> {"Failed", "error"}
        :rolled_back -> {"Rolled Back", "error"}
        :canceled -> {"Canceled", "ghost"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
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

  defp normalize_release_form(%Form{} = form), do: form
  defp normalize_release_form(_other), do: release_form()

  defp normalize_rollout_form(%Form{} = form, releases) do
    params = form.params || %{}
    rollout_form(params, releases)
  end

  defp normalize_rollout_form(_other, releases), do: rollout_form(%{}, releases)

  defp rollout_prefill_params(params) when is_map(params) do
    compact_map(%{
      "version" => presence(Map.get(params, "version")),
      "cohort" => presence(Map.get(params, "cohort")),
      "agent_ids" => normalize_prefill_agent_ids(Map.get(params, "agent_ids")),
      "batch_size" => presence(Map.get(params, "batch_size")),
      "batch_delay_seconds" => presence(Map.get(params, "batch_delay_seconds")),
      "notes" => presence(Map.get(params, "notes"))
    })
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
      compact_map(%{
        "url" => presence(params["artifact_url"]),
        "sha256" => presence(params["artifact_sha256"]),
        "os" => presence(params["os"]),
        "arch" => presence(params["arch"]),
        "format" => presence(params["artifact_format"]),
        "entrypoint" => presence(params["entrypoint"])
      })

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

  defp empty_rollout_preview do
    %{
      cohort: "connected",
      selected_count: 0,
      compatible_count: 0,
      unsupported_count: 0,
      unknown_count: 0,
      supported_platforms: [],
      unsupported_agents: [],
      unknown_agent_ids: [],
      release_missing?: true
    }
  end

  defp build_rollout_preview(params, releases, connected_agents, scope) do
    selected_release =
      params
      |> Map.get("version")
      |> presence()
      |> find_release_by_version(releases)

    {selected_agents, unknown_agent_ids, selected_count, cohort} =
      rollout_preview_targets(params, connected_agents, scope)

    unsupported_agents =
      case selected_release do
        nil ->
          []

        release ->
          selected_agents
          |> Enum.filter(&(not release_supports_agent?(release, &1)))
          |> Enum.map(fn agent ->
            %{
              agent_id: agent.uid,
              platform_label: agent_platform_label(agent) || "unknown platform"
            }
          end)
      end

    %{
      cohort: cohort,
      selected_count: selected_count,
      compatible_count: max(length(selected_agents) - length(unsupported_agents), 0),
      unsupported_count: length(unsupported_agents),
      unknown_count: length(unknown_agent_ids),
      supported_platforms: if(selected_release, do: artifact_platforms(selected_release.manifest), else: []),
      unsupported_agents: Enum.take(unsupported_agents, 8),
      unknown_agent_ids: Enum.take(unknown_agent_ids, 8),
      release_missing?: is_nil(selected_release)
    }
  end

  defp rollout_preview_targets(params, connected_agents, scope) do
    case Map.get(params, "cohort") do
      "custom" ->
        agent_ids = rollout_agent_ids(params, connected_agents)
        agents = list_agents_by_uid(agent_ids, scope)
        agents_by_uid = Map.new(agents, &{&1.uid, &1})

        selected_agents =
          agent_ids
          |> Enum.map(&Map.get(agents_by_uid, &1))
          |> Enum.reject(&is_nil/1)

        unknown_agent_ids =
          Enum.reject(agent_ids, fn agent_id ->
            Map.has_key?(agents_by_uid, agent_id)
          end)

        {selected_agents, unknown_agent_ids, length(agent_ids), "custom"}

      _ ->
        {connected_agents, [], length(connected_agents), "connected"}
    end
  end

  defp list_agents_by_uid([], _scope), do: []

  defp list_agents_by_uid(agent_ids, scope) do
    Agent
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(uid in ^agent_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, agents} -> agents
      {:error, _} -> []
    end
  end

  defp find_release_by_version(nil, _releases), do: nil

  defp find_release_by_version(version, releases) do
    Enum.find(releases, &(&1.version == version))
  end

  defp release_supports_agent?(release, %Agent{metadata: metadata}) when is_map(metadata) do
    release
    |> artifact_list()
    |> Enum.any?(fn artifact ->
      artifact_matches_platform?(
        artifact_field(artifact, "os"),
        artifact_field(artifact, "arch"),
        Map.get(metadata, "os"),
        Map.get(metadata, "arch")
      )
    end)
  end

  defp release_supports_agent?(_release, _agent), do: false

  defp artifact_matches_platform?(artifact_os, artifact_arch, agent_os, agent_arch) do
    (is_nil(artifact_os) or artifact_os == agent_os) and
      (is_nil(artifact_arch) or artifact_arch == agent_arch)
  end

  defp show_rollout_preview?(preview) do
    preview.selected_count > 0 or
      preview.supported_platforms != [] or
      preview.unknown_agent_ids != []
  end

  defp rollout_submit_disabled?([], _preview), do: true
  defp rollout_submit_disabled?(_releases, preview), do: not rollout_preview_actionable?(preview)

  defp rollout_preview_actionable?(preview) do
    not preview.release_missing? and
      preview.selected_count > 0 and
      preview.unsupported_count == 0 and
      preview.unknown_count == 0
  end

  defp rollout_preview_block_message(preview) do
    cond do
      preview.release_missing? ->
        "Rollout creation is blocked until you select a published release."

      preview.selected_count == 0 ->
        "Rollout creation is blocked until the current cohort resolves to at least one agent."

      preview.unknown_count > 0 ->
        "Rollout creation is blocked until unresolved agent IDs are corrected or removed."

      preview.unsupported_count > 0 ->
        "Rollout creation is blocked until the cohort matches the published release platforms."

      true ->
        nil
    end
  end

  defp rollout_preview_scope_text(%{cohort: "custom"}), do: "Current custom cohort"
  defp rollout_preview_scope_text(_preview), do: "Current connected cohort"

  defp release_options(releases) do
    Enum.map(releases, fn release -> {release.version, release.version} end)
  end

  defp artifact_list(%{"artifacts" => artifacts}) when is_list(artifacts), do: artifacts
  defp artifact_list(%{artifacts: artifacts}) when is_list(artifacts), do: artifacts
  defp artifact_list(_manifest), do: []

  defp artifact_platforms(%{"artifacts" => artifacts}) when is_list(artifacts) do
    artifacts
    |> Enum.map(&artifact_platform_label/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp artifact_platforms(%{artifacts: artifacts}) when is_list(artifacts),
    do: artifact_platforms(%{"artifacts" => artifacts})

  defp artifact_platforms(_manifest), do: []

  defp artifact_platform_label(artifact) when is_map(artifact) do
    platform_label(artifact_field(artifact, "os"), artifact_field(artifact, "arch"))
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
    %{total: 0, healthy: 0, failed: 0, rolled_back: 0, inflight: 0, state_counts: %{}}
  end

  defp rollout_progress_badges(summary) do
    for status <- [
          :pending,
          :dispatched,
          :downloading,
          :verifying,
          :staged,
          :restarting,
          :failed,
          :rolled_back,
          :canceled
        ],
        count = Map.get(summary.state_counts, status, 0),
        count > 0 do
      {label, variant} = rollout_progress_badge_meta(status, count)
      %{label: label, variant: variant}
    end
  end

  defp rollout_progress_badge_meta(:pending, count), do: {"#{count} pending", "ghost"}
  defp rollout_progress_badge_meta(:dispatched, count), do: {"#{count} dispatched", "info"}
  defp rollout_progress_badge_meta(:downloading, count), do: {"#{count} downloading", "info"}
  defp rollout_progress_badge_meta(:verifying, count), do: {"#{count} verifying", "info"}
  defp rollout_progress_badge_meta(:staged, count), do: {"#{count} staged", "warning"}
  defp rollout_progress_badge_meta(:restarting, count), do: {"#{count} restarting", "warning"}
  defp rollout_progress_badge_meta(:failed, count), do: {"#{count} failed", "error"}
  defp rollout_progress_badge_meta(:rolled_back, count), do: {"#{count} rolled back", "error"}
  defp rollout_progress_badge_meta(:canceled, count), do: {"#{count} canceled", "ghost"}

  defp target_progress_summary(target) do
    [
      target.progress_percent && "#{target.progress_percent}%",
      present_text(target.last_status_message),
      format_datetime(target.updated_at || target.inserted_at)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp rollout_version(%{desired_version: version}) when is_binary(version) and version != "", do: version

  defp rollout_version(%{release: %{version: version}}) when is_binary(version), do: version
  defp rollout_version(_rollout), do: "—"

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(other), do: to_string(other)

  defp format_error(%{errors: errors}) when is_list(errors), do: Enum.map_join(errors, "; ", &format_error/1)
  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp display_target_platform(%{platform_label: platform_label, target: target}) do
    platform_label || platform_label_from_error(target.last_error)
  end

  defp display_target_platform(_detail), do: nil

  defp platform_mismatch_error?(error) when is_binary(error) do
    String.contains?(error, "no matching release artifact for agent platform ")
  end

  defp platform_mismatch_error?(_error), do: false

  defp platform_label_from_error(error) when is_binary(error) do
    case Regex.run(~r/agent platform ([[:alnum:]_.-]+\/[[:alnum:]_.-]+)/, error, capture: :all_but_first) do
      [platform] -> platform
      _ -> nil
    end
  end

  defp platform_label_from_error(_error), do: nil

  defp agent_platform_label(%Agent{metadata: metadata}) when is_map(metadata) do
    platform_label(Map.get(metadata, "os"), Map.get(metadata, "arch"))
  end

  defp agent_platform_label(_agent), do: nil

  defp platform_label(os, arch) do
    case {presence(os), presence(arch)} do
      {nil, nil} -> nil
      {os, nil} -> os
      {nil, arch} -> arch
      {os, arch} -> "#{os}/#{arch}"
    end
  end

  defp artifact_field(artifact, "os") when is_map(artifact), do: Map.get(artifact, "os") || Map.get(artifact, :os)
  defp artifact_field(artifact, "arch") when is_map(artifact), do: Map.get(artifact, "arch") || Map.get(artifact, :arch)
  defp artifact_field(_artifact, _key), do: nil

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(_value), do: nil

  defp maybe_refresh_for_release_command(socket, data) do
    if release_command_event?(data), do: schedule_refresh(socket), else: socket
  end

  defp release_command_event?(data) when is_map(data) do
    Map.get(data, :command_type) == @release_command_type ||
      Map.get(data, "command_type") == @release_command_type
  end

  defp release_command_event?(_data), do: false

  defp schedule_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      nil ->
        ref = Process.send_after(self(), :refresh_releases_page, 250)
        assign(socket, :refresh_timer, ref)

      _ref ->
        socket
    end
  end

  defp rollout_prefill_message(count, "agent_detail"), do: "Prefilled #{count} agent from the detail view."

  defp rollout_prefill_message(count, "agents_selection"),
    do: "Prefilled #{count} selected agents from the inventory view."

  defp rollout_prefill_message(count, _source), do: "Prefilled #{count} visible agents from the inventory view."

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp presence(value) do
    case value do
      nil ->
        nil

      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        value
    end
  end

  defp blank?(value), do: is_nil(presence(value))
end
