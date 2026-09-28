defmodule ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver do
  @moduledoc false

  # Resolves the profile that applies to a device: the SRQL-targeted profile
  # when one matches, otherwise the default profile when the caller supplies a
  # `:default_resolver`.
  #
  # A failed profile read is returned as `{:error, reason}`, never as "no
  # profile". The compilers built on this feed `ConfigServer`, which caches every
  # `{:ok, config}` it is handed. Reporting a failed read as `{:ok, nil}` made a
  # transient database error indistinguishable from "no profile applies": the
  # compiler returned its disabled config, the cache kept it for the agent, and
  # every later generation for that agent hashed the disabled fragment instead of
  # the real profile, re-versioning the agent config until the next invalidation.

  require Logger

  @type result :: {:ok, term() | nil} | {:error, term()}

  # `:resolver` is `(device_uid, actor -> result)`. The optional
  # `:default_resolver` is `(actor -> result)`.
  @spec resolve(String.t() | nil, term(), keyword()) :: result()
  def resolve(nil, actor, opts), do: resolve_default_profile(actor, opts)

  def resolve(device_uid, actor, opts) when is_binary(device_uid) do
    case Keyword.fetch!(opts, :resolver).(device_uid, actor) do
      {:ok, nil} ->
        resolve_default_profile(actor, opts)

      {:ok, profile} ->
        {:ok, profile}

      {:error, reason} ->
        Logger.warning("#{log_prefix(opts)}: SRQL targeting failed - #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_default_profile(actor, opts) do
    case Keyword.get(opts, :default_resolver) do
      nil -> {:ok, nil}
      resolver -> resolver.(actor)
    end
  end

  defp log_prefix(opts), do: Keyword.get(opts, :log_prefix, "TargetedProfileResolver")
end
