defmodule ServiceRadarWebNGWeb.Settings.UiPreferenceController do
  @moduledoc """
  Flips the per-user `settings_ui` preference (`:original | :catalog`) that
  toggles between the legacy Settings chrome and the new catalog-driven shell.

  The preference is stored in the session (web-ng only — no core schema change),
  read back by `ServiceRadarWebNGWeb.Settings.ShellHook` at mount. The default is
  `:original`, so existing users are unaffected until they explicitly opt in.
  """

  use ServiceRadarWebNGWeb, :controller

  alias ServiceRadarWebNGWeb.Settings.ShellHook

  @allowed_modes ~w(original catalog)
  @default_return "/settings/audit/events"

  def update(conn, params) do
    mode = normalize_mode(params["mode"])
    return_to = safe_return(params["return_to"])

    conn
    |> put_session(ShellHook.session_key(), mode)
    |> redirect(to: return_to)
  end

  defp normalize_mode(mode) when mode in @allowed_modes, do: mode
  defp normalize_mode(_), do: "original"

  # Only allow local Settings redirects to avoid open-redirect abuse.
  defp safe_return(path) when is_binary(path) do
    if String.starts_with?(path, "/settings"), do: path, else: @default_return
  end

  defp safe_return(_), do: @default_return
end
