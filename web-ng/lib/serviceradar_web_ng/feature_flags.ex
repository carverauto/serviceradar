defmodule ServiceRadarWebNG.FeatureFlags do
  @moduledoc """
  Feature flags for gradual Ash Framework migration rollout.

  These flags control which domains use Ash resources vs legacy Ecto contexts.
  Enable flags incrementally as each domain migration is complete and tested.

  ## Configuration

  Set feature flags in config:

      config :serviceradar_web_ng, :feature_flags,
        ash_identity_domain: true,
        ash_inventory_domain: false

  Or via environment variables at runtime:

      FEATURE_ASH_IDENTITY_DOMAIN=true
  """

  @doc """
  Check if a feature flag is enabled.

  Returns the configured value, checking environment variables first,
  then falling back to application config.

  ## Examples

      iex> FeatureFlags.enabled?(:ash_identity_domain)
      false

      iex> FeatureFlags.enabled?(:ash_authentication)
      true
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(flag) when is_atom(flag) do
    env_var = flag |> to_string() |> String.upcase() |> then(&"FEATURE_#{&1}")

    case System.get_env(env_var) do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      nil -> get_config_flag(flag)
      _ -> get_config_flag(flag)
    end
  end

  @doc """
  Get all feature flags and their current values.
  """
  @spec all() :: keyword(boolean())
  def all do
    Application.get_env(:serviceradar_web_ng, :feature_flags, [])
    |> Enum.map(fn {flag, default} ->
      {flag, enabled?(flag) || default}
    end)
  end

  defp get_config_flag(flag) do
    :serviceradar_web_ng
    |> Application.get_env(:feature_flags, [])
    |> Keyword.get(flag, false)
  end
end
