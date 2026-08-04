defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Events.Profiles do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias AshPhoenix.Form
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Data
  alias ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.Targeting

  def handle_event("validate_profile", %{"form" => params}, socket) do
    target_query = Map.get(params, "target_query")
    params = params |> Data.normalize_agent_ids_param() |> Data.normalize_credential_secret_param()
    ash_form = Form.validate(socket.assigns.ash_form, params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> Targeting.assign_target_preview(target_query)}
  end

  def handle_event("save_profile", %{"form" => params}, socket) do
    params =
      if socket.assigns.show_form == :edit_profile do
        sensitive_fields = ["community", "auth_password", "priv_password"]

        Map.reject(params, fn {key, value} ->
          key in sensitive_fields and value == ""
        end)
      else
        params
      end

    # Drop the hidden empty agent_ids placeholder so unchecking every box
    # persists [] (legacy all-agents) rather than [""].
    params = params |> Data.normalize_agent_ids_param() |> Data.normalize_credential_secret_param()

    # Include selected OID template IDs
    params = Map.put(params, "oid_template_ids", socket.assigns.selected_template_ids)

    ash_form = Form.validate(socket.assigns.ash_form, params)
    scope = socket.assigns.current_scope

    case Form.submit(ash_form, params: params) do
      {:ok, _profile} ->
        action = if socket.assigns.show_form == :new_profile, do: "created", else: "updated"

        {:noreply,
         socket
         |> Data.assign_profiles_with_counts(scope)
         |> put_flash(:info, "Profile #{action} successfully")
         |> push_navigate(to: ~p"/settings/snmp")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))}
    end
  end

  def handle_event("toggle_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        new_enabled = !profile.enabled
        changeset = Ash.Changeset.for_update(profile, :update, %{enabled: new_enabled})

        case Ash.update(changeset, scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> Data.assign_profiles_with_counts(scope)
             |> put_flash(:info, "Profile #{if new_enabled, do: "enabled", else: "disabled"}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update profile")}
        end
    end
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      %{is_default: true} ->
        {:noreply, put_flash(socket, :error, "Cannot delete the default profile")}

      profile ->
        case Ash.destroy(profile, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> Data.assign_profiles_with_counts(scope)
             |> put_flash(:info, "Profile deleted")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete profile")}
        end
    end
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        case profile
             |> Ash.Changeset.for_update(:set_as_default, %{})
             |> Ash.update(scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> Data.assign_profiles_with_counts(scope)
             |> put_flash(:info, "#{profile.name} is now the default profile")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to set as default")}
        end
    end
  end

  # Builder event handlers
end
