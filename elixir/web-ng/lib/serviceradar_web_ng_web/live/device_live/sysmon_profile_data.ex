defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonProfileData do
  @moduledoc false

  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  require Logger

  def load_profile_info(scope, device_uid) do
    actor = profile_actor(scope)
    available_profiles = load_available_profiles(actor)
    profile = SysmonCompiler.resolve_profile(device_uid, actor)

    source =
      cond do
        is_nil(profile) -> "unassigned"
        not is_nil(profile.target_query) -> "srql"
        true -> "unassigned"
      end

    {%{profile: profile, source: source}, available_profiles}
  rescue
    error ->
      Logger.warning("Failed to load sysmon profile info: #{inspect(error)}")
      {nil, []}
  end

  defp profile_actor(%{user: user}) when not is_nil(user), do: user
  defp profile_actor(_), do: nil

  defp load_available_profiles(actor) do
    case Ash.read(SysmonProfile, action: :list_available, actor: actor) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end
end
