defmodule ServiceRadarWebNGWeb.Settings.RemoteAccessDesktopTargetsLive do
  @moduledoc """
  Operator settings page for registered RDP desktop targets.
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Edge.RemoteAccessDesktopTarget
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNG.RemoteAccessDesktopTargets
  alias ServiceRadarWebNGWeb.FeatureFlags

  @current_path "/settings/networks/desktop-targets"
  @manage_permission "settings.edge.manage"
  @credential_modes %{
    "domain_delegation" => :domain_delegation,
    "smart_card" => :smart_card,
    "certificate" => :certificate,
    "user_present" => :user_present,
    "centrally_brokered" => :centrally_brokered
  }
  @target_kinds %{"inventory_device" => :inventory_device, "freeform_target" => :freeform_target}
  @clipboard_modes ~w(disabled local_to_remote remote_to_local bidirectional)
  @recording_modes ~w(metadata_only screen_content)
  @target_tls_modes ~w(verify_ca skip_verify)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    cond do
      not FeatureFlags.remote_access_desktop_rdp_enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, "RDP remote access is not enabled")
         |> redirect(to: ~p"/settings/profile")}

      not can_manage?(scope) ->
        {:ok,
         socket
         |> put_flash(:error, "Not authorized to manage RDP desktop targets")
         |> redirect(to: ~p"/settings/profile")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "RDP Desktop Targets")
         |> assign(:current_path, @current_path)
         |> assign(:targets, [])
         |> assign(:loading?, true)
         |> assign(:form_mode, nil)
         |> assign(:editing_target, nil)
         |> assign(:target_form, target_form(default_target_params()))}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:current_path, @current_path)
      |> assign(:form_mode, socket.assigns.live_action)

    if connected?(socket) do
      {:noreply, load_page(socket, params)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_target", %{"desktop_target" => params}, socket) do
    {:noreply, assign(socket, :target_form, target_form(normalize_form_params(params)))}
  end

  def handle_event("save_target", %{"desktop_target" => params}, socket) do
    case normalize_target_attrs(params) do
      {:ok, attrs} ->
        save_target(socket, attrs)

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:target_form, target_form(normalize_form_params(params)))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("disable_target", %{"id" => id}, socket) do
    set_enabled(socket, id, false, "RDP desktop target disabled")
  end

  def handle_event("enable_target", %{"id" => id}, socket) do
    set_enabled(socket, id, true, "RDP desktop target enabled")
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:target_kind_options, enum_options(Map.keys(@target_kinds)))
      |> assign(:credential_mode_options, enum_options(Map.keys(@credential_modes)))
      |> assign(:target_tls_mode_options, enum_options(@target_tls_modes))
      |> assign(:clipboard_mode_options, enum_options(@clipboard_modes))
      |> assign(:recording_mode_options, enum_options(@recording_modes))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path={@current_path}>
        <div class="space-y-4">
          <.settings_nav current_path={@current_path} current_scope={@current_scope} />
          <.network_nav current_path={@current_path} current_scope={@current_scope} />
        </div>

        <section class="space-y-4">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h1 class="text-xl font-semibold">RDP Desktop Targets</h1>
              <p class="mt-1 text-sm text-base-content/70">
                Register trusted Windows desktop endpoints that users can open through routed agents.
              </p>
            </div>
            <.link
              navigate={~p"/settings/networks/desktop-targets/new"}
              class="btn btn-primary btn-sm"
            >
              New Target
            </.link>
          </div>

          <div class="overflow-hidden rounded-lg border border-base-200 bg-base-100">
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Target</th>
                    <th>Route</th>
                    <th>Credential</th>
                    <th>Policy</th>
                    <th>Status</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={@loading?}>
                    <td colspan="7" class="py-8 text-center text-sm text-base-content/60">
                      Loading RDP desktop targets.
                    </td>
                  </tr>
                  <tr :if={!@loading? and @targets == []}>
                    <td colspan="7" class="py-8 text-center text-sm text-base-content/60">
                      No RDP desktop targets found.
                    </td>
                  </tr>
                  <tr :for={target <- @targets}>
                    <td>
                      <div class="font-medium">{target.name}</div>
                      <div :if={target.description} class="text-xs text-base-content/60">
                        {target.description}
                      </div>
                    </td>
                    <td>
                      <div>{target.target_host}:{target.target_port}</div>
                      <div class="text-xs text-base-content/60">{target.device_uid}</div>
                    </td>
                    <td>
                      <div>{target.agent_id || "-"}</div>
                      <div :if={target.gateway_id} class="text-xs text-base-content/60">
                        {target.gateway_id}
                      </div>
                    </td>
                    <td>
                      <span class="badge badge-sm badge-ghost">
                        {enum_label(target.credential_custody_mode)}
                      </span>
                    </td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <span class="badge badge-sm badge-outline">
                          TLS {policy_value(target.target_tls, "mode", "verify_ca")}
                        </span>
                        <span class="badge badge-sm badge-outline">
                          NLA {if policy_value(target.nla, "required", true),
                            do: "required",
                            else: "optional"}
                        </span>
                        <span class="badge badge-sm badge-outline">
                          Clipboard {policy_value(target.redirection_policy, "clipboard", "disabled")}
                        </span>
                      </div>
                    </td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        if(target.enabled, do: "badge-success", else: "badge-ghost")
                      ]}>
                        {if target.enabled, do: "Enabled", else: "Disabled"}
                      </span>
                    </td>
                    <td class="text-right">
                      <div class="flex justify-end gap-2">
                        <.link
                          navigate={~p"/settings/networks/desktop-targets/#{target.id}/edit"}
                          class="btn btn-ghost btn-xs"
                        >
                          Edit
                        </.link>
                        <button
                          :if={target.enabled}
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="disable_target"
                          phx-value-id={target.id}
                        >
                          Disable
                        </button>
                        <button
                          :if={!target.enabled}
                          type="button"
                          class="btn btn-ghost btn-xs"
                          phx-click="enable_target"
                          phx-value-id={target.id}
                        >
                          Enable
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>

        <.target_form_modal
          :if={@form_mode in [:new, :edit]}
          form={@target_form}
          mode={@form_mode}
          target_kind_options={@target_kind_options}
          credential_mode_options={@credential_mode_options}
          target_tls_mode_options={@target_tls_mode_options}
          clipboard_mode_options={@clipboard_mode_options}
          recording_mode_options={@recording_mode_options}
        />
      </.settings_shell>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :mode, :atom, required: true
  attr :target_kind_options, :list, required: true
  attr :credential_mode_options, :list, required: true
  attr :target_tls_mode_options, :list, required: true
  attr :clipboard_mode_options, :list, required: true
  attr :recording_mode_options, :list, required: true

  defp target_form_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-5xl rounded-lg">
        <div class="mb-4 flex items-center justify-between">
          <h2 class="text-lg font-semibold">
            {if @mode == :new, do: "New RDP Desktop Target", else: "Edit RDP Desktop Target"}
          </h2>
          <.link navigate={~p"/settings/networks/desktop-targets"} class="btn btn-ghost btn-sm">
            Close
          </.link>
        </div>

        <.form for={@form} phx-change="change_target" phx-submit="save_target" class="space-y-5">
          <div class="grid gap-4 md:grid-cols-2">
            <.input field={@form[:name]} label="Name" required />
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label="Enabled"
            />
            <.input field={@form[:description]} type="textarea" label="Description" />
            <.input
              field={@form[:target_kind]}
              type="select"
              label="Target Kind"
              options={@target_kind_options}
              required
            />
            <.input field={@form[:device_uid]} label="Device UID" required />
            <.input field={@form[:target_host]} label="Target Host" required />
            <.input
              field={@form[:target_port]}
              type="number"
              label="Target Port"
              min="1"
              max="65535"
              required
            />
            <.input field={@form[:agent_id]} label="Agent ID" />
            <.input field={@form[:gateway_id]} label="Gateway ID" />
            <.input
              field={@form[:credential_custody_mode]}
              type="select"
              label="Credential Mode"
              options={@credential_mode_options}
              required
            />
            <.input field={@form[:credential_rule_id]} label="Credential Rule ID" />
          </div>

          <div class="grid gap-4 lg:grid-cols-3">
            <fieldset class="rounded-lg border border-base-300 p-4">
              <legend class="px-1 text-sm font-medium">Desktop Security</legend>
              <div class="space-y-3">
                <.input
                  field={@form[:target_tls_mode]}
                  type="select"
                  label="Target TLS"
                  options={@target_tls_mode_options}
                  required
                />
                <.input field={@form[:nla_required]} type="checkbox" label="Require NLA" />
                <.input
                  field={@form[:recording_mode]}
                  type="select"
                  label="Recording"
                  options={@recording_mode_options}
                  required
                />
              </div>
            </fieldset>

            <fieldset class="rounded-lg border border-base-300 p-4">
              <legend class="px-1 text-sm font-medium">Screen Policy</legend>
              <div class="grid gap-3 sm:grid-cols-2">
                <.input field={@form[:max_width]} type="number" label="Max Width" min="1" />
                <.input field={@form[:max_height]} type="number" label="Max Height" min="1" />
                <.input field={@form[:frame_rate]} type="number" label="FPS" min="1" />
                <.input field={@form[:bitrate_kbps]} type="number" label="Kbps" min="1" />
              </div>
            </fieldset>

            <fieldset class="rounded-lg border border-base-300 p-4">
              <legend class="px-1 text-sm font-medium">Redirection</legend>
              <.input
                field={@form[:clipboard]}
                type="select"
                label="Clipboard"
                options={@clipboard_mode_options}
                required
              />
            </fieldset>
          </div>

          <.input
            field={@form[:allowed_principals]}
            type="textarea"
            label="Allowed Principals"
          />

          <div class="modal-action">
            <.link navigate={~p"/settings/networks/desktop-targets"} class="btn btn-ghost">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <.link navigate={~p"/settings/networks/desktop-targets"} class="modal-backdrop">Close</.link>
    </div>
    """
  end

  defp load_page(socket, params) do
    case RemoteAccessDesktopTargets.list_managed(socket.assigns.current_scope) do
      {:ok, targets} ->
        socket
        |> assign(:targets, targets)
        |> assign(:loading?, false)
        |> assign_form(params, targets)

      {:error, reason} ->
        socket
        |> assign(:targets, [])
        |> assign(:loading?, false)
        |> put_flash(:error, "Failed to load RDP desktop targets: #{format_error(reason)}")
    end
  end

  defp assign_form(%{assigns: %{form_mode: :new}} = socket, _params, _targets) do
    socket
    |> assign(:editing_target, nil)
    |> assign(:target_form, target_form(default_target_params()))
  end

  defp assign_form(%{assigns: %{form_mode: :edit}} = socket, params, targets) do
    case Enum.find(targets, &(to_string(&1.id) == to_string(params["id"]))) do
      nil ->
        socket
        |> put_flash(:error, "RDP desktop target not found")
        |> push_patch(to: ~p"/settings/networks/desktop-targets")

      target ->
        socket
        |> assign(:editing_target, target)
        |> assign(:target_form, target_form(target_params(target)))
    end
  end

  defp assign_form(socket, _params, _targets) do
    socket
    |> assign(:editing_target, nil)
    |> assign(:target_form, target_form(default_target_params()))
  end

  defp save_target(%{assigns: %{form_mode: :new}} = socket, attrs) do
    case RemoteAccessDesktopTargets.create_managed(socket.assigns.current_scope, attrs) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, "RDP desktop target created")
         |> push_patch(to: ~p"/settings/networks/desktop-targets")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create RDP desktop target: #{format_error(reason)}")}
    end
  end

  defp save_target(%{assigns: %{form_mode: :edit, editing_target: %RemoteAccessDesktopTarget{} = target}} = socket, attrs) do
    case RemoteAccessDesktopTargets.update_managed(socket.assigns.current_scope, target, attrs) do
      {:ok, _target} ->
        {:noreply,
         socket
         |> put_flash(:info, "RDP desktop target updated")
         |> push_patch(to: ~p"/settings/networks/desktop-targets")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update RDP desktop target: #{format_error(reason)}")}
    end
  end

  defp save_target(socket, _attrs) do
    {:noreply, put_flash(socket, :error, "No RDP desktop target selected")}
  end

  defp set_enabled(socket, id, enabled, success_message) do
    with %RemoteAccessDesktopTarget{} = target <- Enum.find(socket.assigns.targets, &(to_string(&1.id) == to_string(id))),
         {:ok, _target} <- RemoteAccessDesktopTargets.set_managed_enabled(socket.assigns.current_scope, target, enabled) do
      {:noreply,
       socket
       |> put_flash(:info, success_message)
       |> load_page(%{})}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "RDP desktop target not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update RDP desktop target: #{format_error(reason)}")}
    end
  end

  defp normalize_target_attrs(params) do
    with {:ok, name} <- required_string(params, "name"),
         {:ok, device_uid} <- required_string(params, "device_uid"),
         {:ok, target_host} <- required_string(params, "target_host"),
         {:ok, target_port} <- parse_port(params["target_port"]),
         {:ok, target_kind} <- enum_value(params["target_kind"], @target_kinds, "target_kind"),
         {:ok, credential_mode} <-
           enum_value(params["credential_custody_mode"], @credential_modes, "credential_custody_mode"),
         {:ok, credential_rule_id} <- optional_uuid(params["credential_rule_id"]) do
      {:ok,
       %{
         name: name,
         description: blank_to_nil(params["description"]),
         enabled: truthy?(params["enabled"]),
         target_kind: target_kind,
         device_uid: device_uid,
         target_host: target_host,
         target_port: target_port,
         agent_id: blank_to_nil(params["agent_id"]),
         gateway_id: blank_to_nil(params["gateway_id"]),
         credential_custody_mode: credential_mode,
         credential_rule_id: credential_rule_id,
         approval_required: false,
         allowed_principals: split_principals(params["allowed_principals"]),
         target_tls: %{"mode" => safe_option(params["target_tls_mode"], @target_tls_modes, "verify_ca")},
         nla: %{"required" => truthy?(params["nla_required"])},
         screen_policy: screen_policy(params),
         redirection_policy: %{"clipboard" => safe_option(params["clipboard"], @clipboard_modes, "disabled")},
         recording_policy: %{"mode" => safe_option(params["recording_mode"], @recording_modes, "metadata_only")}
       }}
    end
  end

  defp required_string(params, key) do
    case blank_to_nil(params[key]) do
      nil -> {:error, "Required fields are missing"}
      value -> {:ok, value}
    end
  end

  defp parse_port(value) do
    case parse_positive_integer(value) do
      port when is_integer(port) and port <= 65_535 -> {:ok, port}
      _ -> {:error, "Target port must be between 1 and 65535"}
    end
  end

  defp optional_uuid(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      value ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, "Credential rule ID must be a valid UUID"}
        end
    end
  end

  defp enum_value(value, allowed, field) do
    value = blank_to_nil(value)

    case Map.fetch(allowed, value) do
      {:ok, enum} -> {:ok, enum}
      :error -> {:error, "#{field} is invalid"}
    end
  end

  defp screen_policy(params) do
    %{}
    |> put_positive_integer("max_width", params["max_width"])
    |> put_positive_integer("max_height", params["max_height"])
    |> put_positive_integer("frame_rate", params["frame_rate"])
    |> put_positive_integer("bitrate_kbps", params["bitrate_kbps"])
  end

  defp put_positive_integer(map, key, value) do
    case parse_positive_integer(value) do
      integer when is_integer(integer) -> Map.put(map, key, integer)
      nil -> map
    end
  end

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp default_target_params do
    %{
      "name" => "",
      "description" => "",
      "enabled" => "true",
      "target_kind" => "inventory_device",
      "device_uid" => "",
      "target_host" => "",
      "target_port" => "3389",
      "agent_id" => "",
      "gateway_id" => "",
      "credential_custody_mode" => "user_present",
      "credential_rule_id" => "",
      "target_tls_mode" => "verify_ca",
      "nla_required" => "true",
      "recording_mode" => "metadata_only",
      "max_width" => "",
      "max_height" => "",
      "frame_rate" => "",
      "bitrate_kbps" => "",
      "clipboard" => "disabled",
      "allowed_principals" => ""
    }
  end

  defp target_params(%RemoteAccessDesktopTarget{} = target) do
    Map.merge(default_target_params(), %{
      "name" => target.name || "",
      "description" => target.description || "",
      "enabled" => if(target.enabled, do: "true", else: "false"),
      "target_kind" => to_string(target.target_kind || :inventory_device),
      "device_uid" => target.device_uid || "",
      "target_host" => target.target_host || "",
      "target_port" => to_string(target.target_port || 3389),
      "agent_id" => target.agent_id || "",
      "gateway_id" => target.gateway_id || "",
      "credential_custody_mode" => to_string(target.credential_custody_mode || :user_present),
      "credential_rule_id" => target.credential_rule_id || "",
      "target_tls_mode" => policy_value(target.target_tls, "mode", "verify_ca"),
      "nla_required" => if(policy_value(target.nla, "required", true), do: "true", else: "false"),
      "recording_mode" => policy_value(target.recording_policy, "mode", "metadata_only"),
      "max_width" => policy_number(target.screen_policy, "max_width"),
      "max_height" => policy_number(target.screen_policy, "max_height"),
      "frame_rate" => policy_number(target.screen_policy, "frame_rate"),
      "bitrate_kbps" => policy_number(target.screen_policy, "bitrate_kbps"),
      "clipboard" => policy_value(target.redirection_policy, "clipboard", "disabled"),
      "allowed_principals" => Enum.join(target.allowed_principals || [], "\n")
    })
  end

  defp normalize_form_params(params), do: Map.merge(default_target_params(), Map.new(params))
  defp target_form(params), do: to_form(normalize_form_params(params), as: :desktop_target)

  defp split_principals(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_principals(_value), do: []

  defp safe_option(value, allowed, default) do
    value = blank_to_nil(value) || default
    if value in allowed, do: value, else: default
  end

  defp truthy?(value) when value in [true, "true", "1", "yes", "on"], do: true
  defp truthy?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp policy_value(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp policy_value(_map, _key, default), do: default

  defp policy_number(map, key) do
    case policy_value(map, key, nil) do
      value when is_integer(value) -> to_string(value)
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp enum_options(values), do: Enum.map(values, &{enum_label(&1), &1})
  defp enum_label(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp can_manage?(scope), do: RBAC.can?(scope, @manage_permission)

  defp format_error(%Ash.Error.Invalid{} = error), do: Exception.message(error)
  defp format_error(%Ash.Error.Forbidden{} = error), do: Exception.message(error)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: reason |> to_string() |> String.replace("_", " ")
  defp format_error(reason), do: inspect(reason)
end
