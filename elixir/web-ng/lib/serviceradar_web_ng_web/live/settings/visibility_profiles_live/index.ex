defmodule ServiceRadarWebNGWeb.Settings.VisibilityProfilesLive.Index do
  @moduledoc """
  LiveView for host network visibility profile management.
  """
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.QueryBuilderComponents
  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.AgentConfig.Compilers.VisibilityCompiler
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.SRQL.Catalog

  @current_path "/settings/networks/visibility-profiles"
  @read_permission "visibility_profiles:read"
  @write_permission "visibility_profiles:write"
  @delete_permission "visibility_profiles:delete"
  @default_partition "default"
  @default_sample_interval_ms 60_000
  @default_retention_days 30

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @read_permission) do
      socket =
        socket
        |> assign(:page_title, "Visibility Profiles")
        |> assign(:current_path, @current_path)
        |> assign(:profiles, load_profiles(scope))
        |> assign(:selected_profile, nil)
        |> assign(:show_form, nil)
        |> assign(:form, default_form())
        |> assign(:errors, [])
        |> assign(:json_preview, nil)
        |> assign(:target_device_count, nil)
        |> assign(:builder_open, false)
        |> assign(:builder, default_builder_state())
        |> assign(:builder_sync, true)
        |> assign(:can_write, RBAC.can?(scope, @write_permission))
        |> assign(:can_delete, RBAC.can?(scope, @delete_permission))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have access to Visibility Profiles")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Visibility Profiles")
    |> assign(:show_form, nil)
    |> assign(:selected_profile, nil)
    |> assign(:form, default_form())
    |> assign(:errors, [])
    |> assign(:json_preview, nil)
    |> assign(:target_device_count, nil)
    |> assign(:builder_open, false)
    |> assign(:builder, default_builder_state())
    |> assign(:builder_sync, true)
  end

  defp apply_action(socket, :new_profile, _params) do
    if socket.assigns.can_write do
      socket
      |> assign(:page_title, "New Visibility Profile")
      |> assign(:show_form, :new_profile)
      |> assign(:selected_profile, nil)
      |> assign(:form, default_form())
      |> assign(:errors, [])
      |> assign(:json_preview, nil)
      |> assign(:target_device_count, nil)
      |> assign(:builder_open, false)
      |> assign(:builder, default_builder_state())
      |> assign(:builder_sync, true)
    else
      socket
      |> put_flash(:error, "You cannot create Visibility Profiles")
      |> push_navigate(to: ~p"/settings/networks/visibility-profiles")
    end
  end

  defp apply_action(socket, :edit_profile, %{"id" => id}) do
    if socket.assigns.can_write do
      case load_profile(socket.assigns.current_scope, id) do
        nil ->
          socket
          |> put_flash(:error, "Visibility Profile not found")
          |> push_navigate(to: ~p"/settings/networks/visibility-profiles")

        profile ->
          form = form_from_profile(profile)
          device_count = count_target_devices(socket.assigns.current_scope, profile.target_query)
          {builder, builder_sync} = parse_target_query_to_builder(profile.target_query)

          socket
          |> assign(:page_title, "Edit #{profile.name}")
          |> assign(:show_form, :edit_profile)
          |> assign(:selected_profile, profile)
          |> assign(:form, form)
          |> assign(:errors, [])
          |> assign(:json_preview, compile_profile_preview(profile))
          |> assign(:target_device_count, device_count)
          |> assign(:builder_open, false)
          |> assign(:builder, builder)
          |> assign(:builder_sync, builder_sync)
      end
    else
      socket
      |> put_flash(:error, "You cannot edit Visibility Profiles")
      |> push_navigate(to: ~p"/settings/networks/visibility-profiles")
    end
  end

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    form = normalize_form(params)
    {builder, builder_sync} = parse_target_query_to_builder(form["target_query"])

    socket =
      socket
      |> assign(:form, form)
      |> assign(:errors, validate_form(form))
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, form["target_query"]))
      |> assign(:builder_sync, builder_sync)

    socket = if builder_sync, do: assign(socket, :builder, builder), else: socket

    {:noreply, socket}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    if socket.assigns.can_write do
      form = normalize_form(params)

      case validate_form(form) do
        [] ->
          save_profile(socket, form)

        errors ->
          {:noreply, socket |> assign(:form, form) |> assign(:errors, errors)}
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot save Visibility Profiles")}
    end
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    if socket.assigns.can_write do
      scope = socket.assigns.current_scope

      case load_profile(scope, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Visibility Profile not found")}

        profile ->
          profile
          |> Ash.Changeset.for_update(:update, %{enabled: !profile.enabled})
          |> Ash.update(scope: scope)
          |> case do
            {:ok, _updated} ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile updated")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, error_message(reason))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot update Visibility Profiles")}
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    if socket.assigns.can_delete do
      scope = socket.assigns.current_scope

      case load_profile(scope, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Visibility Profile not found")}

        profile ->
          case Ash.destroy(profile, scope: scope) do
            :ok ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile deleted")}

            {:ok, _} ->
              _ = ConfigServer.invalidate(:visibility)

              {:noreply,
               socket
               |> assign(:profiles, load_profiles(scope))
               |> put_flash(:info, "Visibility Profile deleted")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, error_message(reason))}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "You cannot delete Visibility Profiles")}
    end
  end

  def handle_event("preview_json", %{"id" => id}, socket) do
    case load_profile(socket.assigns.current_scope, id) do
      nil -> {:noreply, put_flash(socket, :error, "Visibility Profile not found")}
      profile -> {:noreply, assign(socket, :json_preview, compile_profile_preview(profile))}
    end
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :json_preview, nil)}
  end

  def handle_event("builder_toggle", _params, socket) do
    if socket.assigns.builder_open do
      {:noreply, assign(socket, :builder_open, false)}
    else
      {builder, builder_sync} = parse_target_query_to_builder(socket.assigns.form["target_query"])

      {:noreply,
       socket
       |> assign(:builder_open, true)
       |> assign(:builder, builder)
       |> assign(:builder_sync, builder_sync)}
    end
  end

  def handle_event("builder_change", %{"builder" => builder_params}, socket) do
    builder = update_builder(socket.assigns.builder, builder_params)

    {:noreply,
     socket
     |> assign(:builder, builder)
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_add_filter", _params, socket) do
    config = Catalog.entity("devices")
    builder = socket.assigns.builder
    filters = Map.get(builder, "filters", [])

    filter = %{
      "field" => config.default_filter_field,
      "op" => "contains",
      "value" => ""
    }

    {:noreply,
     socket
     |> assign(:builder, Map.put(builder, "filters", filters ++ [filter]))
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_remove_filter", %{"idx" => idx_str}, socket) do
    idx = parse_int(idx_str, -1)
    builder = socket.assigns.builder

    filters =
      builder
      |> Map.get("filters", [])
      |> Enum.with_index()
      |> Enum.reject(fn {_filter, i} -> i == idx end)
      |> Enum.map(fn {filter, _i} -> filter end)

    filters = if filters == [], do: default_builder_state()["filters"], else: filters

    {:noreply,
     socket
     |> assign(:builder, Map.put(builder, "filters", filters))
     |> assign(:builder_sync, true)
     |> maybe_sync_builder_to_form()}
  end

  def handle_event("builder_apply", _params, socket) do
    query = build_target_query(socket.assigns.builder)
    form = Map.put(socket.assigns.form, "target_query", query)

    {:noreply,
     socket
     |> assign(:form, form)
     |> assign(:errors, validate_form(form))
     |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
     |> assign(:builder_sync, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <.settings_nav current_path={@current_path} current_scope={@current_scope} />
        <.discovery_nav current_path={@current_path} current_scope={@current_scope} />

        <%= if @show_form in [:new_profile, :edit_profile] do %>
          <.profile_form
            form={@form}
            errors={@errors}
            show_form={@show_form}
            selected_profile={@selected_profile}
            target_device_count={@target_device_count}
            builder_open={@builder_open}
            builder={@builder}
            builder_sync={@builder_sync}
          />
        <% else %>
          <.profiles_panel profiles={@profiles} can_write={@can_write} can_delete={@can_delete} />
        <% end %>

        <.json_preview_modal :if={@json_preview && @show_form == nil} json_preview={@json_preview} />
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :profiles, :list, required: true
  attr :can_write, :boolean, default: false
  attr :can_delete, :boolean, default: false

  defp profiles_panel(assigns) do
    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">Visibility Profiles</div>
            <p class="text-xs text-base-content/60">
              {length(@profiles)} profile(s) configured
            </p>
          </div>
          <.link :if={@can_write} navigate={~p"/settings/networks/visibility-profiles/new"}>
            <.ui_button variant="primary" size="sm">
              <.icon name="hero-plus" class="size-4" /> New Profile
            </.ui_button>
          </.link>
        </div>
      </:header>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr class="text-xs uppercase tracking-wide text-base-content/60">
              <th>Status</th>
              <th>Name</th>
              <th>Targeting</th>
              <th>Sample</th>
              <th>Fingerprint</th>
              <th>Retention</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@profiles == []}>
              <td colspan="7" class="text-center text-base-content/60 py-8">
                No visibility profiles configured.
              </td>
            </tr>
            <%= for profile <- @profiles do %>
              <tr class="hover:bg-base-200/40">
                <td>
                  <button
                    :if={@can_write}
                    phx-click="toggle_profile"
                    phx-value-id={profile.id}
                    class="flex items-center gap-1.5 cursor-pointer"
                  >
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                    </span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </button>
                  <div :if={not @can_write} class="flex items-center gap-1.5">
                    <span class={"size-2 rounded-full #{if profile.enabled, do: "bg-success", else: "bg-base-content/30"}"}>
                    </span>
                    <span class="text-xs">{if profile.enabled, do: "Enabled", else: "Disabled"}</span>
                  </div>
                </td>
                <td>
                  <.link
                    :if={@can_write}
                    navigate={~p"/settings/networks/visibility-profiles/#{profile.id}/edit"}
                    class="font-medium hover:text-primary"
                  >
                    {profile.name}
                  </.link>
                  <span :if={not @can_write} class="font-medium">{profile.name}</span>
                  <p :if={profile.description} class="text-xs text-base-content/60 truncate max-w-xs">
                    {profile.description}
                  </p>
                </td>
                <td class="text-xs max-w-xs">
                  <%= if profile.target_query && profile.target_query != "" do %>
                    <code class="font-mono text-[11px] bg-base-200/50 px-1.5 py-0.5 rounded truncate block max-w-[220px]">
                      {profile.target_query}
                    </code>
                  <% else %>
                    <span class="text-base-content/40">in:devices</span>
                  <% end %>
                </td>
                <td class="font-mono text-xs">{profile.sample_interval_ms} ms</td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <.ui_badge :if={fingerprint_enabled?(profile, "tcp")} variant="ghost" size="xs">
                      TCP
                    </.ui_badge>
                    <.ui_badge :if={fingerprint_enabled?(profile, "tls")} variant="ghost" size="xs">
                      TLS
                    </.ui_badge>
                    <.ui_badge :if={fingerprint_enabled?(profile, "http")} variant="ghost" size="xs">
                      HTTP
                    </.ui_badge>
                  </div>
                </td>
                <td class="font-mono text-xs">{profile.retention_days}d</td>
                <td>
                  <div class="flex items-center gap-1">
                    <.ui_button
                      variant="ghost"
                      size="xs"
                      phx-click="preview_json"
                      phx-value-id={profile.id}
                      title="Preview config"
                    >
                      <.icon name="hero-code-bracket" class="size-3" />
                    </.ui_button>
                    <.link
                      :if={@can_write}
                      navigate={~p"/settings/networks/visibility-profiles/#{profile.id}/edit"}
                    >
                      <.ui_button variant="ghost" size="xs" title="Edit profile">
                        <.icon name="hero-pencil" class="size-3" />
                      </.ui_button>
                    </.link>
                    <.ui_button
                      :if={@can_delete}
                      variant="ghost"
                      size="xs"
                      phx-click="delete_profile"
                      phx-value-id={profile.id}
                      data-confirm="Delete this visibility profile?"
                      title="Delete profile"
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </.ui_button>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ui_panel>
    """
  end

  attr :form, :map, required: true
  attr :errors, :list, default: []
  attr :show_form, :atom, required: true
  attr :selected_profile, :any, default: nil
  attr :target_device_count, :integer, default: nil
  attr :builder_open, :boolean, default: false
  attr :builder, :map, required: true
  attr :builder_sync, :boolean, default: true

  defp profile_form(assigns) do
    config = Catalog.entity("devices")

    assigns =
      assigns
      |> assign(:device_fields, config.fields)
      |> assign(:filter_ops, [
        {"contains", "contains"},
        {"equals", "equals"},
        {"not contains", "not_contains"},
        {"not equals", "not_equals"}
      ])

    ~H"""
    <.ui_panel>
      <:header>
        <div class="flex items-center justify-between w-full">
          <div>
            <div class="text-sm font-semibold">
              {if @show_form == :new_profile,
                do: "New Visibility Profile",
                else: "Edit Visibility Profile"}
            </div>
            <p class="text-xs text-base-content/60">
              {target_count_label(@target_device_count)}
            </p>
          </div>
          <.link navigate={~p"/settings/networks/visibility-profiles"}>
            <.ui_button variant="ghost" size="sm">
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.ui_button>
          </.link>
        </div>
      </:header>

      <form
        id="visibility-profile-form"
        phx-change="validate_profile"
        phx-submit="save_profile"
        class="space-y-6"
      >
        <div :if={@errors != []} class="alert alert-error">
          <ul class="text-sm">
            <li :for={error <- @errors}>{error}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.text_input name="form[name]" label="Name" value={@form["name"]} required />
          <.number_input name="form[priority]" label="Priority" value={@form["priority"]} />
          <.text_input name="form[description]" label="Description" value={@form["description"]} />
          <.number_input
            name="form[sample_interval_ms]"
            label="Sample interval ms"
            value={@form["sample_interval_ms"]}
            min="0"
          />
          <.number_input
            name="form[retention_days]"
            label="Retention days"
            value={@form["retention_days"]}
            min="1"
          />
          <label class="label cursor-pointer justify-start gap-3">
            <input type="hidden" name="form[enabled]" value="false" />
            <input
              type="checkbox"
              name="form[enabled]"
              value="true"
              class="toggle toggle-primary"
              checked={truthy?(@form["enabled"])}
            />
            <span class="label-text">Enabled</span>
          </label>
        </div>

        <div class="rounded-lg border border-base-200 p-4 space-y-3">
          <div class="flex items-center justify-between">
            <div>
              <div class="text-sm font-semibold">Targeting</div>
              <p class="text-xs text-base-content/60">{target_count_label(@target_device_count)}</p>
            </div>
            <.ui_button
              type="button"
              variant={if @builder_open, do: "primary", else: "ghost"}
              size="sm"
              phx-click="builder_toggle"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4" /> Query Builder
            </.ui_button>
          </div>

          <textarea
            name="form[target_query]"
            class="textarea textarea-bordered w-full font-mono text-xs"
            rows="3"
          >{@form["target_query"]}</textarea>

          <div :if={@builder_open} class="rounded-lg bg-base-200/40 p-3 space-y-3">
            <div class="flex items-center justify-between">
              <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Device filters
              </div>
              <.ui_button :if={not @builder_sync} type="button" size="xs" phx-click="builder_apply">
                Apply
              </.ui_button>
            </div>
            <form id="visibility-builder-form" phx-change="builder_change" phx-debounce="200"></form>
            <%= for {filter, idx} <- Enum.with_index(@builder["filters"] || []) do %>
              <div class="flex flex-wrap items-center gap-2">
                <.query_builder_pill label="Filter">
                  <select
                    class="select select-bordered select-xs"
                    name={"builder[filters][#{idx}][field]"}
                    form="visibility-builder-form"
                  >
                    <option
                      :for={field <- @device_fields}
                      value={field.name}
                      selected={filter["field"] == field.name}
                    >
                      {field.label}
                    </option>
                  </select>
                  <select
                    class="select select-bordered select-xs"
                    name={"builder[filters][#{idx}][op]"}
                    form="visibility-builder-form"
                  >
                    <option
                      :for={{label, value} <- @filter_ops}
                      value={value}
                      selected={filter["op"] == value}
                    >
                      {label}
                    </option>
                  </select>
                  <input
                    class="input input-bordered input-xs w-44"
                    name={"builder[filters][#{idx}][value]"}
                    form="visibility-builder-form"
                    value={filter["value"]}
                  />
                </.query_builder_pill>
                <.ui_button
                  type="button"
                  variant="ghost"
                  size="xs"
                  phx-click="builder_remove_filter"
                  phx-value-idx={idx}
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </.ui_button>
              </div>
            <% end %>
            <.ui_button type="button" variant="ghost" size="sm" phx-click="builder_add_filter">
              <.icon name="hero-plus" class="size-4" /> Filter
            </.ui_button>
          </div>
        </div>

        <div class="rounded-lg border border-base-200 p-4 space-y-3">
          <div class="text-sm font-semibold">Passive Fingerprinting</div>
          <div class="flex flex-wrap gap-4">
            <.fingerprint_toggle
              name="tcp"
              label="TCP"
              checked={truthy?(@form["fingerprint"]["tcp"])}
            />
            <.fingerprint_toggle
              name="tls"
              label="TLS"
              checked={truthy?(@form["fingerprint"]["tls"])}
            />
            <.fingerprint_toggle
              name="http"
              label="HTTP"
              checked={truthy?(@form["fingerprint"]["http"])}
            />
          </div>
          <div class="flex flex-wrap gap-2 pt-2">
            <.ui_badge variant="ghost" size="sm">DPI later phase</.ui_badge>
            <.ui_badge variant="ghost" size="sm">Flow attribution later phase</.ui_badge>
            <.ui_badge variant="ghost" size="sm">Process snapshots later phase</.ui_badge>
          </div>
        </div>

        <div class="flex justify-end gap-2">
          <.link navigate={~p"/settings/networks/visibility-profiles"}>
            <.ui_button type="button" variant="ghost">Cancel</.ui_button>
          </.link>
          <.ui_button type="submit" variant="primary">
            <.icon name="hero-check" class="size-4" /> Save Profile
          </.ui_button>
        </div>
      </form>
    </.ui_panel>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false

  defp fingerprint_toggle(assigns) do
    ~H"""
    <label class="label cursor-pointer justify-start gap-3">
      <input type="hidden" name={"form[fingerprint][#{@name}]"} value="false" />
      <input
        type="checkbox"
        name={"form[fingerprint][#{@name}]"}
        value="true"
        class="checkbox checkbox-primary checkbox-sm"
        checked={@checked}
      />
      <span class="label-text">{@label}</span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: ""
  attr :required, :boolean, default: false

  defp text_input(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text text-xs">{@label}</span>
      <input
        type="text"
        name={@name}
        value={@value}
        required={@required}
        class="input input-bordered input-sm w-full"
      />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: ""
  attr :min, :string, default: nil

  defp number_input(assigns) do
    ~H"""
    <label class="form-control">
      <span class="label-text text-xs">{@label}</span>
      <input
        type="number"
        name={@name}
        value={@value}
        min={@min}
        class="input input-bordered input-sm w-full"
      />
    </label>
    """
  end

  attr :json_preview, :string, required: true

  defp json_preview_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">Compiled Visibility Config</h3>
        <pre class="bg-base-200/50 p-4 rounded-lg text-xs font-mono overflow-x-auto max-h-96">{@json_preview}</pre>
        <div class="modal-action">
          <button phx-click="close_preview" class="btn">Close</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_preview"></div>
    </div>
    """
  end

  defp save_profile(socket, form) do
    scope = socket.assigns.current_scope
    attrs = form_attrs(form)

    result =
      case socket.assigns.show_form do
        :new_profile ->
          VisibilityProfile
          |> Ash.Changeset.for_create(:create, attrs)
          |> Ash.create(scope: scope)

        :edit_profile ->
          socket.assigns.selected_profile
          |> Ash.Changeset.for_update(:update, attrs)
          |> Ash.update(scope: scope)
      end

    case result do
      {:ok, _profile} ->
        _ = ConfigServer.invalidate(:visibility)

        {:noreply,
         socket
         |> assign(:profiles, load_profiles(scope))
         |> put_flash(:info, "Visibility Profile saved")
         |> push_navigate(to: ~p"/settings/networks/visibility-profiles")}

      {:error, reason} ->
        {:noreply, socket |> assign(:form, form) |> assign(:errors, [error_message(reason)])}
    end
  end

  defp load_profiles(scope) do
    case Ash.read(VisibilityProfile, scope: scope) do
      {:ok, profiles} -> Enum.sort_by(profiles, fn profile -> {-profile.priority, profile.name} end)
      {:error, _reason} -> []
    end
  end

  defp load_profile(scope, id) do
    case Ash.get(VisibilityProfile, id, scope: scope) do
      {:ok, profile} -> profile
      {:error, _reason} -> nil
    end
  end

  defp compile_profile_preview(profile) do
    profile
    |> VisibilityCompiler.compile_profile("192.0.2.10")
    |> Jason.encode!(pretty: true)
  rescue
    _ -> ~s({"error":"Failed to compile visibility config"})
  end

  defp default_form do
    %{
      "name" => "",
      "description" => "",
      "enabled" => "true",
      "target_query" => "",
      "priority" => "0",
      "sample_interval_ms" => Integer.to_string(@default_sample_interval_ms),
      "retention_days" => Integer.to_string(@default_retention_days),
      "partition_id" => @default_partition,
      "fingerprint" => %{"tcp" => "true", "tls" => "true", "http" => "true"}
    }
  end

  defp form_from_profile(profile) do
    fingerprint = profile.fingerprint || %{}

    %{
      "name" => profile.name || "",
      "description" => profile.description || "",
      "enabled" => bool_string(profile.enabled),
      "target_query" => profile.target_query || "",
      "priority" => to_string(profile.priority || 0),
      "sample_interval_ms" => to_string(profile.sample_interval_ms || @default_sample_interval_ms),
      "retention_days" => to_string(profile.retention_days || @default_retention_days),
      "partition_id" => profile.partition_id || @default_partition,
      "fingerprint" => %{
        "tcp" => bool_string(map_truthy?(fingerprint, "tcp")),
        "tls" => bool_string(map_truthy?(fingerprint, "tls")),
        "http" => bool_string(map_truthy?(fingerprint, "http"))
      }
    }
  end

  defp normalize_form(params) do
    form = Map.merge(default_form(), stringify_params(params || %{}))
    fingerprint = Map.merge(default_form()["fingerprint"], stringify_params(form["fingerprint"] || %{}))
    Map.put(form, "fingerprint", fingerprint)
  end

  defp form_attrs(form) do
    %{
      name: trim(form["name"]),
      description: blank_to_nil(form["description"]),
      enabled: truthy?(form["enabled"]),
      target_query: blank_to_nil(form["target_query"]),
      priority: parse_int(form["priority"], 0),
      sample_interval_ms: parse_int(form["sample_interval_ms"], @default_sample_interval_ms),
      retention_days: parse_int(form["retention_days"], @default_retention_days),
      partition_id: blank_to_nil(form["partition_id"]) || @default_partition,
      fingerprint: %{
        "tcp" => truthy?(form["fingerprint"]["tcp"]),
        "tls" => truthy?(form["fingerprint"]["tls"]),
        "http" => truthy?(form["fingerprint"]["http"])
      }
    }
  end

  defp validate_form(form) do
    []
    |> maybe_error(trim(form["name"]) == "", "Name is required")
    |> maybe_error(parse_int(form["sample_interval_ms"], -1) < 0, "Sample interval must be zero or greater")
    |> maybe_error(parse_int(form["retention_days"], 0) < 1, "Retention must be at least one day")
  end

  defp maybe_error(errors, true, message), do: [message | errors]
  defp maybe_error(errors, false, _message), do: errors

  defp count_target_devices(_scope, nil), do: nil
  defp count_target_devices(_scope, ""), do: nil

  defp count_target_devices(scope, target_query) when is_binary(target_query) do
    query = String.trim(target_query)

    full_query =
      cond do
        query == "" -> ~s|in:devices stats:"count() as total"|
        String.starts_with?(query, "in:") -> ~s|#{query} stats:"count() as total"|
        true -> ~s|in:devices #{query} stats:"count() as total"|
      end

    case srql_module().query(full_query, %{scope: scope}) do
      {:ok, %{"results" => [%{"total" => count} | _]}} when is_integer(count) -> count
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp target_count_label(nil), do: "Target count unknown"
  defp target_count_label(1), do: "Targets 1 device"
  defp target_count_label(count), do: "Targets #{count} devices"

  defp fingerprint_enabled?(profile, name), do: map_truthy?(profile.fingerprint || %{}, name)
  defp map_truthy?(map, "tcp"), do: Map.get(map, "tcp", Map.get(map, :tcp, false)) in [true, "true", "1", 1]
  defp map_truthy?(map, "tls"), do: Map.get(map, "tls", Map.get(map, :tls, false)) in [true, "true", "1", 1]
  defp map_truthy?(map, "http"), do: Map.get(map, "http", Map.get(map, :http, false)) in [true, "true", "1", 1]
  defp map_truthy?(_map, _key), do: false
  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
  defp bool_string(true), do: "true"
  defp bool_string(_), do: "false"

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp trim(value), do: String.trim(to_string(value || ""))
  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))

  defp stringify_params(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_params(_params), do: %{}

  defp default_builder_state do
    config = Catalog.entity("devices")

    %{
      "filters" => [
        %{"field" => config.default_filter_field, "op" => "contains", "value" => ""}
      ]
    }
  end

  defp parse_target_query_to_builder(nil), do: {default_builder_state(), true}
  defp parse_target_query_to_builder(""), do: {default_builder_state(), true}

  defp parse_target_query_to_builder(query) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {default_builder_state(), true}
    else
      case parse_filters_from_query(query) do
        {:ok, filters} when filters != [] -> {%{"filters" => filters}, true}
        _ -> {default_builder_state(), false}
      end
    end
  end

  defp parse_filters_from_query(query) do
    known_prefixes = ["in:", "limit:", "sort:", "time:"]

    tokens =
      query
      |> String.split(~r/(?<!\\)\s+/, trim: true)
      |> Enum.reject(fn token -> Enum.any?(known_prefixes, &String.starts_with?(token, &1)) end)

    filters = tokens |> Enum.map(&parse_filter_token/1) |> Enum.reject(&is_nil/1)
    if length(filters) == length(tokens), do: {:ok, filters}, else: {:error, :unsupported_query}
  end

  defp parse_filter_token(token) do
    {field, negated} =
      if String.starts_with?(token, "!"), do: {String.replace_prefix(token, "!", ""), true}, else: {token, false}

    case String.split(field, ":", parts: 2) do
      [field_name, value] ->
        {op, final_value} = parse_filter_value(field_name, negated, value)
        %{"field" => String.trim(field_name), "op" => op, "value" => final_value}

      _ ->
        nil
    end
  end

  defp parse_filter_value(field, negated, value) do
    value = value |> String.trim() |> String.replace("\\ ", " ")

    cond do
      list_filter_field?(field) ->
        normalized = value |> normalize_list_value() |> Enum.join(", ")
        {maybe_negate_op("equals", negated), normalized}

      String.contains?(value, "%") ->
        {maybe_negate_op("contains", negated), unwrap_like(value)}

      true ->
        {maybe_negate_op("equals", negated), value}
    end
  end

  defp maybe_negate_op("equals", true), do: "not_equals"
  defp maybe_negate_op("contains", true), do: "not_contains"
  defp maybe_negate_op(op, _), do: op
  defp unwrap_like("%" <> rest), do: rest |> String.trim_trailing("%") |> String.replace("\\ ", " ")
  defp unwrap_like(value), do: value
  defp list_filter_field?(field) when is_binary(field), do: field in ["discovery_sources"]
  defp list_filter_field?(_), do: false

  defp normalize_list_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp update_builder(builder, params) do
    builder
    |> Map.merge(stringify_params(params))
    |> normalize_builder_filters()
  end

  defp normalize_builder_filters(builder) do
    config = Catalog.entity("devices")

    filters =
      builder
      |> Map.get("filters", %{})
      |> normalize_filters_list(config)

    Map.put(builder, "filters", filters)
  end

  defp normalize_filters_list(filters, config) when is_list(filters) do
    Enum.map(filters, fn filter ->
      field = normalize_filter_field(filter["field"], config)
      %{"field" => field, "op" => normalize_filter_op(filter["op"], field), "value" => filter["value"] || ""}
    end)
  end

  defp normalize_filters_list(filters_by_index, config) when is_map(filters_by_index) do
    filters_by_index
    |> Enum.sort_by(fn {key, _value} -> parse_int(key, 0) end)
    |> Enum.map(fn {_key, value} -> value end)
    |> normalize_filters_list(config)
  end

  defp normalize_filters_list(_, config),
    do: [%{"field" => config.default_filter_field, "op" => "contains", "value" => ""}]

  defp normalize_filter_field(nil, config), do: config.default_filter_field
  defp normalize_filter_field("", config), do: config.default_filter_field
  defp normalize_filter_field(field, _config), do: field

  defp normalize_filter_op(op, field) do
    if list_filter_field?(field) do
      if op in ["not_equals", "not_contains"], do: "not_equals", else: "equals"
    else
      if op in ["contains", "not_contains", "equals", "not_equals"], do: op, else: "contains"
    end
  end

  defp build_target_query(builder) do
    builder
    |> Map.get("filters", [])
    |> Enum.map(&build_filter_token/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp build_filter_token(%{"field" => field, "op" => op, "value" => value}) do
    field = String.trim(field || "")
    value = String.trim(value || "")

    cond do
      field == "" or value == "" -> nil
      list_filter_field?(field) -> build_list_filter_token(field, op, value)
      true -> build_scalar_filter_token(field, op, value)
    end
  end

  defp build_filter_token(_), do: nil

  defp build_list_filter_token(field, op, value) do
    token = value |> normalize_list_value() |> Enum.map_join(",", &String.replace(&1, " ", "\\ "))
    if op in ["not_equals", "not_contains"], do: "!#{field}:(#{token})", else: "#{field}:(#{token})"
  end

  defp build_scalar_filter_token(field, op, value) do
    escaped = String.replace(value, " ", "\\ ")

    case op do
      "equals" -> "#{field}:#{escaped}"
      "not_equals" -> "!#{field}:#{escaped}"
      "not_contains" -> "!#{field}:%#{escaped}%"
      _ -> "#{field}:%#{escaped}%"
    end
  end

  defp maybe_sync_builder_to_form(socket) do
    if socket.assigns.builder_sync do
      query = build_target_query(socket.assigns.builder)
      form = Map.put(socket.assigns.form, "target_query", query)

      socket
      |> assign(:form, form)
      |> assign(:target_device_count, count_target_devices(socket.assigns.current_scope, query))
    else
      socket
    end
  end

  defp error_message(reason), do: Exception.message(Ash.Error.to_error_class(reason))
end
