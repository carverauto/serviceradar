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
     |> assign(:save_credential_as_reusable, reuse_flag?(params["save_credential_as_reusable"]))
     |> assign(:credential_name, to_string(params["credential_name"] || ""))
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

    scope = socket.assigns.current_scope

    # "Save as reusable" promotes the credential just typed into the shared
    # inventory and binds the profile to it, rather than encrypting a private
    # copy onto the profile. Done before the profile is written so a failure
    # here surfaces on the form instead of leaving a profile pointing at a
    # credential that was never created.
    case maybe_promote_credential(params, scope) do
      {:ok, params} ->
        submit_profile(socket, params, scope)

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
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

  # Demoting is the only way to retire a default profile: `:destroy` is
  # forbidden while `is_default` is true, and relaxing that guard would make
  # "delete" able to silently remove the fallback every unmatched device uses.
  # Clearing the flag first makes the two steps separately visible.
  def handle_event("clear_default", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Data.load_profile(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Profile not found")}

      profile ->
        case profile
             |> Ash.Changeset.for_update(:unset_default, %{})
             |> Ash.update(scope: scope) do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> Data.assign_profiles_with_counts(scope)
             |> put_flash(
               :info,
               "#{profile.name} is no longer the default. Devices matching no other profile are not polled."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to clear the default profile")}
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

  # Form controls, not profile attributes.
  @credential_control_params ["save_credential_as_reusable", "credential_name"]

  defp submit_profile(socket, params, scope) do
    params = Map.drop(params, @credential_control_params)
    ash_form = Form.validate(socket.assigns.ash_form, params)

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

  # Only promotes when the box is ticked AND no existing credential is already
  # selected -- the two are alternatives, and the form hides the credential
  # inputs entirely while one is selected, so there would be nothing to promote.
  defp maybe_promote_credential(%{"save_credential_as_reusable" => flag} = params, scope)
       when flag in ["true", "on", true] do
    if blank?(params["credential_secret_id"]) do
      promote_credential(params, scope)
    else
      {:ok, params}
    end
  end

  defp maybe_promote_credential(params, _scope), do: {:ok, params}

  defp promote_credential(params, scope) do
    name = String.trim(to_string(params["credential_name"] || ""))

    if name == "" do
      {:error, "Name the credential to save it for reuse."}
    else
      values =
        Map.take(params, [
          "community",
          "username",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      case Data.create_snmp_credential(scope, params["version"] || "v2c", name, values) do
        {:ok, secret} ->
          # Bind the profile to the new credential and drop the values that were
          # just promoted. Leaving them would encrypt a second private copy onto
          # the profile that nothing reads -- the resolver takes the broker path
          # once credential_secret_id is set -- and rotating the shared
          # credential would silently leave that copy stale.
          {:ok,
           params
           |> Map.drop(Map.keys(values))
           |> Map.put("credential_secret_id", secret.id)}

        {:error, {:missing_credential_field, field}} ->
          {:error, "#{field} is required to save this credential for reuse."}

        {:error, _reason} ->
          {:error, "Could not save the credential for reuse. Check the fields and try again."}
      end
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  # These controls are not Ash fields, so phx-change must keep them in assigns
  # or the checkbox re-renders unchecked.
  defp reuse_flag?(flag) when flag in [true, "true", "on", "1"], do: true
  defp reuse_flag?(_flag), do: false
end
