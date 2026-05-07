defmodule ServiceRadar.Observability.MtrSettingsSeeder do
  @moduledoc """
  Seeds MTR diagnostics settings and reconciles Timescale retention policies.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_defaults

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.MtrSettings
  alias ServiceRadar.Observability.MtrSettingsRuntime

  require Logger

  def seed_defaults do
    if repo_enabled?() do
      actor = SystemActor.system(:mtr_settings_seeder)
      opts = [actor: actor]

      settings = ensure_settings(opts)

      if settings do
        case MtrSettings.apply_retention_policy(settings) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to reconcile MTR retention: #{inspect(reason)}")
        end

        _ = MtrSettingsRuntime.force_refresh()
      end
    end
  end

  defp ensure_settings(opts) do
    case MtrSettings.get_settings(opts) do
      {:ok, %MtrSettings{} = settings} ->
        settings

      {:ok, nil} ->
        create_default(opts)

      {:error, reason} ->
        if not_found?(reason) do
          create_default(opts)
        else
          Logger.warning("Failed to load MTR settings: #{inspect(reason)}")
          nil
        end
    end
  end

  defp create_default(opts) do
    attrs = %{
      mtr_retention_days: configured_retention_days(),
      mtr_default_history_window: "last_30d",
      mtr_history_page_size_default: 50
    }

    case MtrSettings.create_settings(attrs, opts) do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        Logger.warning("Failed to seed MTR settings: #{inspect(reason)}")
        nil
    end
  end

  defp configured_retention_days do
    :serviceradar_core
    |> Application.get_env(:mtr_retention_days, MtrSettings.default_retention_days())
    |> parse_days(MtrSettings.default_retention_days())
    |> max(1)
    |> min(395)
  end

  defp parse_days(value, _default) when is_integer(value), do: value

  defp parse_days(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} -> days
      _ -> default
    end
  end

  defp parse_days(_value, default), do: default

  defp not_found?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
  end

  defp not_found?(_), do: false
end
