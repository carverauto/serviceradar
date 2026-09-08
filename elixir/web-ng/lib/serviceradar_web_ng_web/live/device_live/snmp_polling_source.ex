defmodule ServiceRadarWebNGWeb.DeviceLive.SNMPPollingSource do
  @moduledoc false

  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.SNMPProfiles.CredentialResolver

  require Logger

  def empty do
    %{
      source: :none,
      source_label: "Not configured",
      profile_id: nil,
      profile_name: nil,
      profile_href: nil,
      profile_enabled: nil,
      profile_is_default: false,
      target_query: nil,
      poll_interval: nil,
      version: nil,
      credential_label: "None",
      credential_configured?: false,
      settings_href: "/settings/snmp"
    }
  end

  def load(_scope, nil), do: empty()

  def load(scope, device_uid) when is_binary(device_uid) do
    actor = scope_actor(scope)

    case CredentialResolver.describe_for_device(device_uid, actor) do
      {:ok, description} -> present(description, scope)
      {:error, reason} -> log_and_empty(device_uid, reason)
    end
  rescue
    error -> log_and_empty(device_uid, error)
  end

  def load(_scope, _device_uid), do: empty()

  defp present(description, scope) do
    profile = Map.get(description, :profile)
    profile_id = profile && profile.id

    %{
      source: description.source,
      source_label: source_label(description.source),
      profile_id: profile_id,
      profile_name: profile && profile.name,
      profile_href: profile_href(profile_id),
      profile_enabled: profile && profile.enabled,
      profile_is_default: profile && profile.is_default == true,
      target_query: profile && present_text(profile.target_query),
      poll_interval: profile && profile.poll_interval,
      version: version_label(description.version),
      credential_label: credential_label(description, scope),
      credential_configured?: description.credential_configured? == true,
      settings_href: "/settings/snmp"
    }
  end

  defp source_label(:device_override), do: "Device override"
  defp source_label(:profile), do: "SNMP profile"
  defp source_label(:default_profile), do: "Default profile"
  defp source_label(_), do: "Not configured"

  defp credential_label(%{source: :device_override} = description, scope) do
    case secret_label(description.credential_secret_id, scope) do
      nil -> "Device override"
      label -> "Device override · #{label}"
    end
  end

  defp credential_label(%{credential_secret_id: secret_id} = description, scope) do
    case secret_label(secret_id, scope) do
      nil when description.credential_configured? -> "Stored on this profile"
      nil -> "None"
      label -> label
    end
  end

  defp secret_label(nil, _scope), do: nil
  defp secret_label("", _scope), do: nil

  defp secret_label(secret_id, scope) do
    case NetworkCredentialSecret.get_by_id(secret_id, scope: scope) do
      {:ok, %{name: name} = secret} when is_binary(name) and name != "" ->
        case Map.get(secret, :provider) do
          provider when is_binary(provider) and provider != "" -> "#{name} (#{provider})"
          _ -> name
        end

      _ ->
        "Reusable credential"
    end
  rescue
    _ -> "Reusable credential"
  end

  defp profile_href(nil), do: nil
  defp profile_href(profile_id), do: "/settings/snmp/#{profile_id}/edit"

  defp version_label(nil), do: nil
  defp version_label(version), do: version |> to_string() |> String.upcase()

  defp present_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_text(_value), do: nil

  defp scope_actor(%{user: user}) when not is_nil(user), do: user
  defp scope_actor(_scope), do: nil

  defp log_and_empty(device_uid, reason) do
    Logger.debug("Failed to describe SNMP polling source for #{device_uid}: #{inspect(reason)}")
    empty()
  end
end
