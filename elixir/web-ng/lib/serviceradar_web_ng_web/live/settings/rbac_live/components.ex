defmodule ServiceRadarWebNGWeb.Settings.RbacLive.Components do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:result, :any, required: true)
  attr(:selected_group_id, :string, default: nil)

  def group_profile_controls(assigns) do
    ~H"""
    <section
      class="rounded-xl border border-sr-line bg-sr-surface"
      aria-labelledby="group-profile-title"
    >
      <div class="flex flex-wrap items-start justify-between gap-3 border-b border-sr-line px-5 py-4">
        <div>
          <h2 id="group-profile-title" class="text-sm font-semibold">User group role profiles</h2>
          <p class="mt-1 text-xs text-sr-muted">
            Attach one role profile to each reusable user group. Group permissions augment each member's base profile.
          </p>
        </div>
      </div>

      <.async_result :let={data} assign={@result}>
        <:loading><.group_profile_loading /></:loading>
        <:failed :let={_reason}><.group_profile_error /></:failed>
        <%= if data.groups == [] do %>
          <.group_profile_empty />
        <% else %>
          <.group_profile_success data={data} selected_group_id={@selected_group_id} />
        <% end %>
      </.async_result>
    </section>
    """
  end

  def group_profile_loading(assigns) do
    ~H"""
    <div
      id="rbac-group-profile-loading"
      data-state="loading"
      class="flex items-center gap-3 px-5 py-6 text-sm text-sr-muted"
    >
      <span
        class="size-4 animate-spin rounded-full border-2 border-sr-line border-t-sr-brand"
        aria-hidden="true"
      ></span>
      <span>Loading user groups...</span>
    </div>
    """
  end

  def group_profile_empty(assigns) do
    ~H"""
    <div id="rbac-group-profile-empty" data-state="empty" class="px-5 py-6">
      <div class="rounded-lg border border-dashed border-sr-line p-4 text-sm text-sr-muted">
        No user groups have been created yet.
      </div>
    </div>
    """
  end

  def group_profile_error(assigns) do
    ~H"""
    <div
      id="rbac-group-profile-error"
      data-state="error"
      role="alert"
      class="flex flex-wrap items-center justify-between gap-3 px-5 py-5"
    >
      <p class="text-sm text-error">Unable to load user groups. Try again.</p>
      <.ui_button type="button" phx-click="retry_group_profiles" size="sm" variant="neutral">
        <.icon name="hero-arrow-path" class="size-4" /> Retry
      </.ui_button>
    </div>
    """
  end

  attr(:data, :map, required: true)
  attr(:selected_group_id, :string, default: nil)

  def group_profile_success(assigns) do
    ~H"""
    <div id="rbac-group-profile-controls" data-state="success" class="divide-y divide-sr-line">
      <article
        :for={group <- @data.groups}
        data-group-profile-row
        data-group-name={group.name}
        class="grid gap-4 px-5 py-4 md:grid-cols-[minmax(0,1fr)_minmax(260px,420px)] md:items-center"
      >
        <div class="min-w-0">
          <h3 class="truncate text-sm font-semibold">{group.name}</h3>
          <p class="mt-1 text-xs text-sr-muted">{group.description || "No description"}</p>
        </div>

        <div class="flex items-center gap-2">
          <.form
            for={to_form(%{})}
            id={"rbac-group-profile-form-#{token_for(@data.group_tokens, group.id)}"}
            phx-change="assign_group_profile"
            class="min-w-0 flex-1"
          >
            <input
              type="hidden"
              name="group-token"
              value={token_for(@data.group_tokens, group.id)}
            />
            <label
              class="sr-only"
              for={"rbac-group-profile-select-#{token_for(@data.group_tokens, group.id)}"}
            >
              Role profile for {group.name}
            </label>
            <select
              id={"rbac-group-profile-select-#{token_for(@data.group_tokens, group.id)}"}
              name="profile-token"
              class={ui_field_class(size: "sm", class: "w-full")}
            >
              <option value="" selected={is_nil(group.role_profile_id)} disabled>
                No role profile assigned
              </option>
              <option
                :for={profile <- @data.profiles}
                data-profile-name={profile.name}
                value={token_for(@data.profile_tokens, profile.id)}
                selected={profile.id == group.role_profile_id}
              >
                {profile.name}
              </option>
            </select>
          </.form>

          <.ui_button
            :if={not is_nil(group.role_profile_id)}
            type="button"
            phx-click="clear_group_profile"
            phx-value-group-token={token_for(@data.group_tokens, group.id)}
            size="sm"
            variant="ghost"
            aria-label={"Clear role profile for #{group.name}"}
          >
            Clear
          </.ui_button>

          <.ui_button
            id={"rbac-dashboard-audience-select-#{token_for(@data.group_tokens, group.id)}"}
            type="button"
            phx-click="select_dashboard_audience_group"
            phx-value-group-token={token_for(@data.group_tokens, group.id)}
            size="sm"
            variant={if(to_string(group.id) == @selected_group_id, do: "primary", else: "neutral")}
            aria-pressed={to_string(group.id) == @selected_group_id}
          >
            Dashboards
          </.ui_button>
        </div>
      </article>
    </div>
    """
  end

  attr(:audience, :map, required: true)
  attr(:group_token, :string, required: true)
  attr(:group_name, :string, required: true)
  attr(:authored_rows, :any, required: true)
  attr(:package_rows, :any, required: true)

  def dashboard_audience(assigns) do
    ~H"""
    <section
      id="rbac-dashboard-audience"
      class="rounded-xl border border-sr-line bg-sr-surface"
      aria-labelledby="rbac-dashboard-audience-title"
    >
      <div class="border-b border-sr-line px-5 py-4">
        <h2 id="rbac-dashboard-audience-title" class="text-sm font-semibold">
          Dashboard audience for {@group_name}
        </h2>
        <p class="mt-1 text-xs text-sr-muted">
          These controls manage explicit group view grants. Source-wide view-all permissions may independently grant access.
        </p>
      </div>

      <div class="grid gap-4 p-4 xl:grid-cols-2">
        <.dashboard_audience_source
          source={:authored}
          state={@audience.authored}
          group_token={@group_token}
          rows={@authored_rows}
        />
        <.dashboard_audience_source
          source={:package}
          state={@audience.package}
          group_token={@group_token}
          rows={@package_rows}
        />
      </div>
    </section>
    """
  end

  attr(:source, :atom, required: true)
  attr(:state, :map, required: true)
  attr(:group_token, :string, required: true)
  attr(:rows, :any, required: true)

  def dashboard_audience_source(assigns) do
    assigns =
      assigns
      |> assign(:title, source_title(assigns.source))
      |> assign(:stream_id, source_stream_id(assigns.source))
      |> assign(:retry_event, source_event(assigns.source, :retry))
      |> assign(:previous_event, source_event(assigns.source, :previous))
      |> assign(:next_event, source_event(assigns.source, :next))

    ~H"""
    <article class="overflow-hidden rounded-lg border border-sr-line" data-dashboard-source={@source}>
      <div class="flex items-center justify-between gap-3 border-b border-sr-line bg-sr-control/40 px-4 py-3">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <span :if={@state.loading?} class="text-xs text-sr-muted">Loading...</span>
      </div>

      <div
        :if={@state.error}
        id={"#{@stream_id}-error"}
        role="alert"
        class="flex items-center justify-between gap-3 border-b border-sr-line px-4 py-3"
      >
        <p class="text-xs text-error">Unable to load dashboards. Try again.</p>
        <.ui_button type="button" phx-click={@retry_event} size="xs" variant="neutral">
          Retry
        </.ui_button>
      </div>

      <div id={@stream_id} phx-update="stream" class="divide-y divide-sr-line">
        <div
          :if={not @state.loading? and is_nil(@state.error)}
          id={"#{@stream_id}-empty"}
          class="hidden only:block px-4 py-6 text-sm text-sr-muted"
        >
          No manageable dashboards found.
        </div>

        <div
          :for={{dom_id, row} <- @rows}
          id={dom_id}
          data-dashboard-row
          data-dashboard-name={row.name}
          class="flex items-center justify-between gap-4 px-4 py-3"
        >
          <div class="min-w-0">
            <p class="truncate text-sm font-medium">{row.name}</p>
            <p :if={row.public? and @source == :authored} class="mt-1 text-xs text-sr-muted">
              Public to users with analytics access
            </p>
            <p :if={row.public? and @source == :package} class="mt-1 text-xs text-sr-muted">
              Public to authenticated users
            </p>
            <p :if={not row.public? and row.access == :edit} class="mt-1 text-xs text-sr-muted">
              Edit access includes view and cannot be removed here
            </p>
            <p :if={not row.public? and row.access == :view} class="mt-1 text-xs text-sr-muted">
              Explicit group view access
            </p>
            <p :if={not row.public? and is_nil(row.access)} class="mt-1 text-xs text-sr-muted">
              No explicit group grant
            </p>
          </div>

          <button
            :if={row.public? or row.access == :edit}
            type="button"
            data-row-token={row.row_token}
            disabled
            class="shrink-0 rounded-sr-control border border-sr-line px-3 py-1.5 text-xs text-sr-muted opacity-70"
          >
            {if(row.public?, do: "Available", else: "Edit")}
          </button>

          <.ui_button
            :if={not row.public? and row.access == :view}
            type="button"
            phx-click={source_event(@source, :revoke)}
            phx-value-group-token={@group_token}
            phx-value-row-token={row.row_token}
            data-row-token={row.row_token}
            size="xs"
            variant="neutral"
          >
            Remove view
          </.ui_button>

          <.ui_button
            :if={not row.public? and is_nil(row.access)}
            type="button"
            phx-click={source_event(@source, :ensure)}
            phx-value-group-token={@group_token}
            phx-value-row-token={row.row_token}
            data-row-token={row.row_token}
            size="xs"
            variant="primary"
          >
            Grant view
          </.ui_button>
        </div>
      </div>

      <div class="flex items-center justify-end gap-2 border-t border-sr-line px-4 py-3">
        <.ui_button
          type="button"
          phx-click={@previous_event}
          disabled={is_nil(@state.before) or @state.loading?}
          size="xs"
          variant="ghost"
        >
          Previous
        </.ui_button>
        <.ui_button
          type="button"
          phx-click={@next_event}
          disabled={is_nil(@state.after) or @state.loading?}
          size="xs"
          variant="ghost"
        >
          Next
        </.ui_button>
      </div>
    </article>
    """
  end

  defp token_for(tokens, id) do
    id = to_string(id)

    Enum.find_value(tokens, fn
      {token, ^id} -> token
      _entry -> nil
    end)
  end

  defp source_title(:authored), do: "Authored dashboards"
  defp source_title(:package), do: "Packaged dashboards"

  defp source_stream_id(:authored), do: "rbac-authored-dashboards"
  defp source_stream_id(:package), do: "rbac-package-dashboards"

  defp source_event(:authored, :retry), do: "retry_authored_dashboard_audience"
  defp source_event(:authored, :previous), do: "previous_authored_dashboard_audience"
  defp source_event(:authored, :next), do: "next_authored_dashboard_audience"
  defp source_event(:authored, :ensure), do: "ensure_authored_dashboard_group_view"
  defp source_event(:authored, :revoke), do: "revoke_authored_dashboard_group_view"
  defp source_event(:package, :retry), do: "retry_package_dashboard_audience"
  defp source_event(:package, :previous), do: "previous_package_dashboard_audience"
  defp source_event(:package, :next), do: "next_package_dashboard_audience"
  defp source_event(:package, :ensure), do: "ensure_package_dashboard_group_view"
  defp source_event(:package, :revoke), do: "revoke_package_dashboard_group_view"
end
