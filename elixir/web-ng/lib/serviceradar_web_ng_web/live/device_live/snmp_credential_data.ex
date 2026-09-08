defmodule ServiceRadarWebNGWeb.DeviceLive.SNMPCredentialData do
  @moduledoc false

  alias ServiceRadar.Inventory.DeviceSNMPCredential

  def load(_scope, nil), do: nil

  def load(scope, device_uid) do
    case DeviceSNMPCredential.get_by_device(device_uid, scope: scope) do
      {:ok, credential} -> credential
      {:error, _} -> nil
    end
  end

  def form_data(nil) do
    %{
      "version" => "v2c",
      "username" => "",
      "security_level" => "no_auth_no_priv",
      "auth_protocol" => "",
      "priv_protocol" => ""
    }
  end

  def form_data(%DeviceSNMPCredential{} = credential) do
    %{
      "version" => to_string(credential.version || :v2c),
      "username" => credential.username || "",
      "security_level" => to_string(credential.security_level || :no_auth_no_priv),
      "auth_protocol" => to_string(credential.auth_protocol || ""),
      "priv_protocol" => to_string(credential.priv_protocol || "")
    }
  end

  def normalize_params(params, editing) do
    params =
      if editing do
        drop_blank(params, ["community", "auth_password", "priv_password"])
      else
        params
      end

    params =
      case Map.get(params, "version") do
        nil -> Map.put(params, "version", "v2c")
        "" -> Map.put(params, "version", "v2c")
        _ -> params
      end

    case Map.get(params, "version") do
      "v1" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v2c" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v3" ->
        Map.delete(params, "community")

      _ ->
        params
    end
  end

  def params_present?(params) do
    Enum.any?(["community", "username", "auth_password", "priv_password"], fn key ->
      value = Map.get(params, key)
      is_binary(value) and String.trim(value) != ""
    end)
  end

  def upsert(scope, device_uid, params) do
    DeviceSNMPCredential.upsert_for_device(device_uid, params, scope: scope)
  end

  def destroy(credential, scope) do
    Ash.destroy(credential, scope: scope)
  end

  defp drop_blank(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end
end
