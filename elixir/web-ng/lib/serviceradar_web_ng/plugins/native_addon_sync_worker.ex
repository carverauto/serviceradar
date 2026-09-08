defmodule ServiceRadarWebNG.Plugins.NativeAddonSyncWorker do
  @moduledoc """
  Periodically imports verified first-party native add-on packages from GitHub Releases.
  """

  use Oban.Worker,
    queue: :web_maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Credentials.CredentialRedactor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.NativeAddonImporter
  alias ServiceRadarWebNG.Plugins.NativeAddonSync

  require Logger

  @default_release_limit 10
  @default_reschedule_seconds 3_600
  @failure_reason_limit 512
  @metadata_limit 128
  @bootstrap_unique [period: :infinity, states: :incomplete]
  @successor_unique [period: :infinity, states: [:available, :scheduled, :retryable]]
  @bootstrap_states ["available", "scheduled", "executing", "retryable", "suspended"]
  @manual_unique [period: :infinity, states: :incomplete, keys: [:force]]

  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> bootstrap_job(schedule_in: 60) |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  @spec enqueue_now(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_now(opts \\ []) do
    args =
      %{"force" => true}
      |> maybe_put("repo_url", Keyword.get(opts, :repo_url))
      |> maybe_put("release_tag", Keyword.get(opts, :release_tag))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    args
    |> manual_job()
    |> ObanSupport.safe_insert()
  end

  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args = args || %{}
    force? = Map.get(args, "force") == true

    result =
      if force? or auto_sync_enabled?() do
        run_sync(args)
      else
        Logger.debug("First-party native add-on sync skipped because auto-sync is disabled")
        :ok
      end

    if !force? and result == :ok do
      schedule_next()
    end

    result
  end

  defp run_sync(args) do
    repo_url = repo_url(args)
    limit = release_limit(args)
    release_tag = release_tag(args)
    addon_ids = requested_addon_ids(args)
    auto_approve_addon_ids = configured_auto_approve_addon_ids()
    discovery_attrs = maybe_put(%{}, :repo_url, repo_url)

    case discover_addons(discovery_attrs, limit, release_tag) do
      {:ok, addons, filter_tag} ->
        results =
          addons
          |> NativeAddonSync.candidates(release_tag: filter_tag, addon_ids: addon_ids)
          |> Enum.map(fn addon ->
            {addon,
             NativeAddonSync.import_or_reuse(addon,
               auto_approve_addon_ids: auto_approve_addon_ids
             )}
          end)

        summary = NativeAddonSync.summary(addons, results)

        failed_count = length(summary.failed)

        message =
          "First-party native add-on sync completed: discovered=#{summary.discovered} " <>
            "import_ready=#{summary.import_ready} imported=#{summary.imported} " <>
            "skipped=#{summary.skipped} failed=#{failed_count}"

        # A partial failure is logged at :error so a run that imported nothing is
        # distinguishable from a healthy one at a glance. It deliberately does NOT
        # fail the job: `perform/1` only calls `schedule_next/0` when the result is
        # :ok, so returning an error on a persistent partial failure would stop the
        # hourly loop entirely -- trading a visible problem for an invisible one.
        if failed_count > 0 do
          Logger.error(message)
        else
          Logger.info(message)
        end

        Enum.each(summary.failed, &log_package_failure/1)

        :ok

      {:error, reason} ->
        if FirstPartyReleaseClient.permanent_failure?(reason) do
          Logger.error("First-party native add-on sync failed",
            reason: bounded_failure_reason(reason)
          )

          :ok
        else
          Logger.warning("First-party native add-on sync failed",
            reason: bounded_failure_reason(reason)
          )

          {:error, reason}
        end
    end
  end

  defp discover_addons(discovery_attrs, limit, release_tag) do
    NativeAddonImporter.list_addons_for_sync(discovery_attrs,
      limit: limit,
      release_tag: release_tag
    )
  end

  defp schedule_next do
    if auto_sync_enabled?() and ObanSupport.available?() do
      case ObanSupport.safe_insert(successor_job(%{}, schedule_in: reschedule_seconds())) do
        {:ok, %Oban.Job{}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to schedule the next first-party native add-on sync",
            reason: bounded_failure_reason(reason)
          )
      end
    end

    :ok
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^inspect(__MODULE__),
        where: j.state in ^@bootstrap_states,
        where: fragment("COALESCE(?->>'force', 'false') <> 'true'", j.args),
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  defp log_package_failure(failure) do
    Logger.warning("First-party native add-on package sync failed",
      addon_id: bounded_metadata(failure.addon_id),
      addon_version: bounded_metadata(failure.version),
      release_tag: bounded_metadata(failure.release_tag),
      reason: bounded_failure_reason(failure.error)
    )
  end

  defp bounded_failure_reason(reason) do
    reason
    |> redact_log_term()
    |> inspect(limit: 20, printable_limit: @failure_reason_limit, width: 120)
    |> redact_inline_secrets()
    |> sanitize_log_text()
    |> String.slice(0, @failure_reason_limit)
  end

  defp bounded_metadata(value) do
    value
    |> redact_log_term()
    |> log_string()
    |> redact_inline_secrets()
    |> sanitize_log_text()
    |> String.slice(0, @metadata_limit)
  end

  defp redact_log_term({key, nested}) when is_atom(key) or is_binary(key) do
    if sensitive_log_key?(key) do
      {key, "REDACTED"}
    else
      {key, redact_log_term(nested)}
    end
  end

  defp redact_log_term(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact_log_term/1)
    |> List.to_tuple()
  end

  defp redact_log_term(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_log_key?(key) do
        {key, "REDACTED"}
      else
        {key, redact_log_term(nested)}
      end
    end)
  end

  defp redact_log_term(value) when is_list(value), do: Enum.map(value, &redact_log_term/1)

  defp redact_log_term(value) when is_binary(value) do
    value
    |> CredentialRedactor.redact()
    |> redact_url_userinfo()
    |> redact_authorization()
    |> redact_inline_secrets()
  end

  defp redact_log_term(value), do: value

  defp redact_inline_secrets(value) when is_binary(value) do
    Regex.replace(
      ~r/(?i)(["']?\b(?:(?:[a-z0-9]+[_-])*(?:token|secret)|api[_-]?key|access[_-]?key|password|passwd|passphrase|private[_-]?key)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;}\]]+)/,
      value,
      "\\1REDACTED"
    )
  end

  defp redact_inline_secrets(value), do: value

  defp redact_authorization(value) when is_binary(value) do
    Regex.replace(
      ~r/(?i)(["']?\b(?:authorization|proxy[_-]?authorization)\b["']?\s*[:=]\s*)(?:"(?:basic|bearer|token)\s+[^"]*"|'(?:basic|bearer|token)\s+[^']*'|(?:basic|bearer|token)\s+[^\s,;}\]]+)/,
      value,
      "\\1REDACTED"
    )
  end

  defp redact_authorization(value), do: value

  defp redact_url_userinfo(value) when is_binary(value) do
    Regex.replace(
      ~r{(?i)\b([a-z][a-z0-9+.-]*://)([^/@\s]+)@},
      value,
      "\\1REDACTED@"
    )
  end

  defp redact_url_userinfo(value), do: value

  defp sensitive_log_key?(key) do
    normalized =
      key
      |> log_key_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    normalized in [
      "authorization",
      "proxy_authorization",
      "provider_auth",
      "provider_bootstrap",
      "credential_material"
    ] or
      Regex.match?(
        ~r/(^|_)(token|secret|password|passwd|passphrase|private_key|api_key|access_key)($|_)/,
        normalized
      )
  end

  defp log_key_string(key) when is_binary(key), do: key
  defp log_key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp log_key_string(key), do: inspect(key, limit: 5, printable_limit: 64)

  defp sanitize_log_text(value) do
    String.replace(value, ~r/[\x00-\x1F\x7F]/u, " ")
  end

  defp log_string(value) when is_binary(value), do: value
  defp log_string(value), do: inspect(value, limit: 10, printable_limit: @metadata_limit)

  defp bootstrap_job(args, opts) do
    new(args, Keyword.put(opts, :unique, @bootstrap_unique))
  end

  defp successor_job(args, opts) do
    new(args, Keyword.put(opts, :unique, @successor_unique))
  end

  defp manual_job(args, opts \\ []) do
    new(args, Keyword.put(opts, :unique, @manual_unique))
  end

  defp auto_sync_enabled? do
    Keyword.get(config(), :auto_sync_enabled, false)
  end

  defp repo_url(args) do
    optional_arg(args, "repo_url") || Keyword.get(config(), :repo_url)
  end

  defp release_tag(args) do
    optional_arg(args, "release_tag") ||
      normalize_optional_string(Keyword.get(config(), :release_tag)) ||
      normalize_optional_string(System.get_env("SERVICERADAR_RELEASE_VERSION"))
  end

  defp requested_addon_ids(args) do
    args
    |> optional_arg("addon_ids")
    |> normalize_string_list([])
  end

  defp configured_auto_approve_addon_ids do
    config()
    |> Keyword.get(:auto_approve_addon_ids, [])
    |> normalize_string_list([])
  end

  defp release_limit(args) do
    args
    |> Map.get("limit")
    |> normalize_positive_integer(Keyword.get(config(), :sync_release_limit, @default_release_limit))
  end

  defp reschedule_seconds do
    config()
    |> Keyword.get(:sync_interval_seconds, @default_reschedule_seconds)
    |> normalize_positive_integer(@default_reschedule_seconds)
    |> max(300)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_string_list(value, _default) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value, default) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_string_list(default)
  end

  defp normalize_string_list(_value, default), do: normalize_string_list(default, [])

  defp optional_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end
  end

  defp config do
    Application.get_env(:serviceradar_web_ng, :native_addon_import, [])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
