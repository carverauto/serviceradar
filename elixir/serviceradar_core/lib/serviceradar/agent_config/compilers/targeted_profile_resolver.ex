defmodule ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver do
  @moduledoc false

  require Logger

  @spec resolve(String.t() | nil, term(), keyword()) :: term() | nil
  def resolve(nil, _actor, _opts), do: nil

  def resolve(device_uid, actor, opts) when is_binary(device_uid) do
    resolve_targeted_profile(device_uid, actor, opts) ||
      resolve_default_profile(actor, opts)
  end

  defp resolve_targeted_profile(device_uid, actor, opts) do
    case Keyword.fetch!(opts, :resolver).(device_uid, actor) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        Logger.warning("#{log_prefix(opts)}: SRQL targeting failed - #{inspect(reason)}")
        nil
    end
  end

  defp resolve_default_profile(actor, opts) do
    case Keyword.get(opts, :default_resolver) do
      nil -> nil
      resolver -> resolver.(actor)
    end
  end

  defp log_prefix(opts), do: Keyword.get(opts, :log_prefix, "TargetedProfileResolver")
end
