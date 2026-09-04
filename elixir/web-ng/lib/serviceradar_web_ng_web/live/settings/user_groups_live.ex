defmodule ServiceRadarWebNGWeb.Settings.UserGroupsLive do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Identity.MappedUserGroups
  alias ServiceRadarWebNG.Dashboards
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/user-groups"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    socket =
      socket
      |> assign(:page_title, "User Groups")
      |> assign(:current_path, @current_path)
      |> assign(:users, [])
      |> assign(:user_groups, [])
      |> assign(:user_group_memberships, [])
      |> assign(:loading?, connected?(socket))
      |> assign(:can_manage_groups?, can_manage_groups?(scope))
      |> assign(:can_view_share_principals?, can_view_share_principals?(scope))
      |> assign(:group_params, default_group_params())
      |> assign(:membership_params, default_membership_params())
      |> assign_group_forms()

    socket =
      if connected?(socket) do
        access_assigns = %{
          can_manage_groups?: socket.assigns.can_manage_groups?,
          can_view_share_principals?: socket.assigns.can_view_share_principals?
        }

        start_async(socket, :load_access_controls, fn -> load_access_controls(scope, access_assigns) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:load_access_controls, {:ok, access}, socket) do
    {:noreply,
     socket
     |> assign(access)
     |> assign(:loading?, false)
     |> assign_group_forms()}
  end

  def handle_async(:load_access_controls, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> put_flash(:error, "Could not load user groups: #{format_error(reason)}")}
  end

  @impl true
  def handle_event("validate_group", %{"group" => params}, socket) do
    {:noreply,
     socket
     |> assign(:group_params, merge_params(socket.assigns.group_params, params))
     |> assign_group_forms()}
  end

  def handle_event("validate_membership", %{"membership" => params}, socket) do
    {:noreply,
     socket
     |> assign(:membership_params, merge_params(socket.assigns.membership_params, params))
     |> assign_group_forms()}
  end

  def handle_event("create_group", %{"group" => params}, socket) do
    case authorize_manage_groups(socket) do
      :ok ->
        case Dashboards.create_user_group(socket.assigns.current_scope, params) do
          {:ok, _group} ->
            {:noreply,
             socket
             |> put_flash(:info, "User group created")
             |> assign(:group_params, default_group_params())
             |> reload_access_controls()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:group_params, params)
             |> assign_group_forms()
             |> put_flash(:error, "User group create failed: #{format_error(reason)}")}
        end

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  def handle_event("add_group_member", %{"membership" => params}, socket) do
    case authorize_manage_groups(socket) do
      :ok ->
        case Dashboards.add_user_group_member(socket.assigns.current_scope, params) do
          {:ok, _membership} ->
            {:noreply,
             socket
             |> put_flash(:info, "Group member added")
             |> assign(:membership_params, default_membership_params())
             |> reload_access_controls()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:membership_params, params)
             |> assign_group_forms()
             |> put_flash(:error, "Group member add failed: #{format_error(reason)}")}
        end

      {:error, _reason} ->
        deny_manage(socket)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
    >
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8">
          <section class="flex flex-col gap-3 border-b border-sr-line pb-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <p class="text-sm font-medium text-sr-brand">Settings</p>
              <h1 class="mt-1 text-2xl font-semibold tracking-normal">User Groups</h1>
              <p class="mt-2 max-w-3xl text-sm text-sr-ink/65">
                Manage reusable groups for dashboard sharing and future access-controlled workflows.
              </p>
            </div>
            <.ui_button navigate={~p"/analytics"} size="sm" variant="ghost">
              <.icon name="hero-squares-2x2" class="size-4" /> Dashboard Creator
            </.ui_button>
          </section>

          <section class="rounded-lg border border-sr-line bg-sr-surface">
            <div class="border-b border-sr-line px-4 py-3">
              <h2 class="text-sm font-semibold">Groups</h2>
            </div>

            <div :if={@loading?} class="p-4 text-sm text-sr-muted">
              Loading groups...
            </div>

            <div :if={!@loading?} class="grid grid-cols-1 gap-6 p-4 lg:grid-cols-[1fr_360px]">
              <div class="space-y-3">
                <div
                  :if={@user_groups == []}
                  class="rounded-lg border border-dashed border-sr-line p-4 text-sm text-sr-muted"
                >
                  No user groups have been created yet.
                </div>

                <article :for={group <- @user_groups} class="rounded-lg border border-sr-line p-4">
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <h3 class="text-sm font-semibold">{group.name}</h3>
                      <p class="mt-1 text-xs text-sr-ink/55">
                        {group.description || "No description"}
                      </p>
                    </div>
                    <.ui_badge size="sm" variant="outline">
                      {membership_count(@user_group_memberships, group.id)} members
                    </.ui_badge>
                  </div>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <span
                      :for={membership <- memberships_for(@user_group_memberships, group.id)}
                      class="inline-flex items-center rounded-full border border-sr-line bg-sr-subtle px-2 text-xs font-semibold text-sr-muted"
                    >
                      {user_label(membership.user)}
                    </span>
                  </div>
                </article>
              </div>

              <div :if={@can_manage_groups?} class="space-y-4">
                <.form
                  for={@group_form}
                  as={:group}
                  phx-change="validate_group"
                  phx-submit="create_group"
                  class="space-y-3"
                >
                  <.input field={@group_form[:name]} type="text" label="Group name" />
                  <.input field={@group_form[:description]} type="text" label="Description" />
                  <.ui_button type="submit" size="sm" variant="primary">
                    <.icon name="hero-user-group" class="size-4" /> Create Group
                  </.ui_button>
                </.form>

                <.form
                  for={@membership_form}
                  as={:membership}
                  phx-change="validate_membership"
                  phx-submit="add_group_member"
                  class="space-y-3 border-t border-sr-line pt-4"
                >
                  <.input
                    field={@membership_form[:group_id]}
                    type="select"
                    label="Group"
                    options={group_select_options(@user_groups)}
                  />
                  <.input
                    field={@membership_form[:user_id]}
                    type="select"
                    label="User"
                    options={user_select_options(@users)}
                  />
                  <.ui_button
                    type="submit"
                    disabled={@user_groups == [] or @users == []}
                    size="sm"
                    variant="neutral"
                  >
                    <.icon name="hero-user-plus" class="size-4" /> Add Member
                  </.ui_button>
                </.form>
              </div>
            </div>
          </section>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp load_access_controls(scope, assigns) do
    if assigns.can_manage_groups? or assigns.can_view_share_principals? do
      MappedUserGroups.reconcile()
    end

    users = if assigns.can_view_share_principals?, do: Dashboards.list_share_principals(scope), else: []

    {groups, memberships} =
      if assigns.can_manage_groups? or assigns.can_view_share_principals? do
        {Dashboards.list_user_groups(scope), Dashboards.list_user_group_memberships(scope)}
      else
        {[], []}
      end

    %{users: users, user_groups: groups, user_group_memberships: memberships}
  end

  defp reload_access_controls(socket) do
    socket
    |> assign(load_access_controls(socket.assigns.current_scope, socket.assigns))
    |> assign_group_forms()
  end

  defp assign_group_forms(socket) do
    socket
    |> assign(:group_form, to_form(socket.assigns.group_params, as: :group))
    |> assign(:membership_form, to_form(socket.assigns.membership_params, as: :membership))
  end

  defp default_group_params, do: %{"name" => "", "description" => ""}
  defp default_membership_params, do: %{"group_id" => "", "user_id" => ""}
  defp merge_params(current, incoming), do: Map.merge(current || %{}, incoming || %{})
  defp can_manage_groups?(scope), do: RBAC.can?(scope, "identity.user_groups.manage")
  defp can_view_share_principals?(scope), do: RBAC.can?(scope, "analytics.share_principals.view")
  defp authorize_manage_groups(socket), do: if(socket.assigns.can_manage_groups?, do: :ok, else: {:error, :forbidden})
  defp deny_manage(socket), do: {:noreply, put_flash(socket, :error, "Not authorized to manage user groups")}
  defp group_select_options(groups), do: Enum.map(groups, &{&1.name, &1.id})
  defp user_select_options(users), do: Enum.map(users, &{user_label(&1), &1.id})
  defp memberships_for(memberships, group_id), do: Enum.filter(memberships, &(&1.group_id == group_id))
  defp membership_count(memberships, group_id), do: memberships |> memberships_for(group_id) |> length()
  defp user_label(%{display_name: name, email: email}) when is_binary(name) and name != "", do: "#{name} <#{email}>"
  defp user_label(%{email: %Ash.CiString{} = email}), do: to_string(email)
  defp user_label(%{email: email}) when is_binary(email), do: email
  defp user_label(_user), do: "Unknown user"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
