defmodule ServiceRadarWebNGWeb.Settings.RbacLive.Components do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  attr(:result, :any, required: true)

  def group_profile_controls(assigns) do
    ~H"""
    <section class="rounded-xl border border-sr-line bg-sr-surface" aria-labelledby="group-profile-title">
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
          <.group_profile_success data={data} />
        <% end %>
      </.async_result>
    </section>
    """
  end

  def group_profile_loading(assigns) do
    ~H"""
    <div id="rbac-group-profile-loading" data-state="loading" class="flex items-center gap-3 px-5 py-6 text-sm text-sr-muted">
      <span class="size-4 animate-spin rounded-full border-2 border-sr-line border-t-sr-brand" aria-hidden="true"></span>
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
    <div id="rbac-group-profile-error" data-state="error" role="alert" class="flex flex-wrap items-center justify-between gap-3 px-5 py-5">
      <p class="text-sm text-error">Unable to load user groups. Try again.</p>
      <.ui_button type="button" phx-click="retry_group_profiles" size="sm" variant="neutral">
        <.icon name="hero-arrow-path" class="size-4" /> Retry
      </.ui_button>
    </div>
    """
  end

  attr(:data, :map, required: true)

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
            <label class="sr-only" for={"rbac-group-profile-select-#{token_for(@data.group_tokens, group.id)}"}>
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
        </div>
      </article>
    </div>
    """
  end

  defp token_for(tokens, id) do
    id = to_string(id)

    Enum.find_value(tokens, fn
      {token, ^id} -> token
      _entry -> nil
    end)
  end
end
