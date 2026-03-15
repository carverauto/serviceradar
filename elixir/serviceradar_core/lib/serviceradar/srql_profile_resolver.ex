defmodule ServiceRadar.SRQLProfileResolver do
  @moduledoc false

  require Logger

  @device_uid_regex ~r/^(?:sr:)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @spec resolve(String.t() | nil, term(), keyword()) :: {:ok, term() | nil} | {:error, term()}
  def resolve(nil, _actor, _opts), do: {:ok, nil}

  def resolve(device_uid, actor, opts) when is_binary(device_uid) do
    if Regex.match?(@device_uid_regex, device_uid) do
      with {:ok, profiles} <- load_profiles(actor, opts) do
        find_matching_profile(profiles, device_uid, actor, opts)
      end
    else
      Logger.debug("#{log_prefix(opts)}: skipping invalid device_uid #{inspect(device_uid)}")
      {:ok, nil}
    end
  end

  defp load_profiles(actor, opts) do
    Keyword.fetch!(opts, :load_profiles).(actor)
  end

  defp find_matching_profile([], _device_uid, _actor, _opts), do: {:ok, nil}

  defp find_matching_profile([profile | rest], device_uid, actor, opts) do
    case Keyword.fetch!(opts, :match_profile).(profile, device_uid, actor) do
      {:ok, true} ->
        Logger.debug("#{log_prefix(opts)}: profile #{profile.id} matches device #{device_uid}")
        {:ok, profile}

      {:ok, false} ->
        find_matching_profile(rest, device_uid, actor, opts)

      {:error, reason} ->
        Logger.warning(
          "#{log_prefix(opts)}: error evaluating profile #{profile.id}: #{inspect(reason)}"
        )

        find_matching_profile(rest, device_uid, actor, opts)
    end
  end

  defp log_prefix(opts), do: Keyword.get(opts, :log_prefix, "SRQLProfileResolver")
end
