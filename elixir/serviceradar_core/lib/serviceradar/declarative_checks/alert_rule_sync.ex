defmodule ServiceRadar.DeclarativeChecks.AlertRuleSync do
  @moduledoc """
  Reconciles `ServiceRadar.Observability.StatefulAlertRule` records from a
  declarative check's `alert_policy` (`2.4`, Decision 6).

  Each declarative check owns at most one deterministic stateful rule named
  `"declarative_check:<slug>"` matching OCSF events emitted by
  `DeclarativeChecks.VerdictEventWriter` (`log_name: "declarative_check.health.state_change"`).
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DeclarativeChecks.VerdictEventWriter
  alias ServiceRadar.Observability.StatefulAlertRule

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:declarative_check_alert_rule_sync)

  @doc "Deterministic `StatefulAlertRule` name for a check slug."
  @spec rule_name(String.t()) :: String.t()
  def rule_name(slug) when is_binary(slug), do: "declarative_check:" <> slug

  @doc """
  Builds the `StatefulAlertRule` attribute map for a `DeclarativeCheck`.
  """
  @spec build_rule_attrs(map()) :: map()
  def build_rule_attrs(check) when is_map(check) do
    slug = to_string(Map.get(check, :slug) || Map.get(check, "slug"))
    name = to_string(Map.get(check, :name) || Map.get(check, "name") || slug)
    state = Map.get(check, :state) || Map.get(check, "state") || :draft
    policy = Map.get(check, :alert_policy) || Map.get(check, "alert_policy") || %{}

    emit? = fetch_val(policy, "emit_ocsf_transition", true) != false
    open_statuses = List.wrap(fetch_val(policy, "open_on_statuses", ["down"]))
    enabled? = state in [:enabled, "enabled"] and emit? and open_statuses != []

    window_seconds = clamp_int(fetch_val(policy, "window_seconds", 300), 60, 86_400)
    bucket_seconds = min(60, window_seconds)
    threshold = clamp_int(fetch_val(policy, "threshold", 1), 1, 1_000)
    cooldown_seconds = clamp_int(fetch_val(policy, "cooldown_seconds", 300), 0, 86_400)
    renotify_seconds = clamp_int(fetch_val(policy, "renotify_seconds", 21_600), 0, 604_800)
    priority = clamp_int(fetch_val(policy, "priority", 3), 1, 100)

    severity =
      if "down" in Enum.map(open_statuses, &to_string/1), do: "critical", else: "warning"

    match_statuses =
      case Enum.map(open_statuses, &to_string/1) do
        [single] -> single
        many -> many
      end

    %{
      name: rule_name(slug),
      description: "Declarative check incident promotion for #{name} (#{slug})",
      enabled: enabled?,
      priority: priority,
      signal: :event,
      match: %{
        "subject_prefix" => VerdictEventWriter.log_name(),
        "attribute_equals" => %{
          "check_slug" => slug,
          "to_status" => match_statuses
        },
        "recovery" => %{
          "subject_prefix" => VerdictEventWriter.log_name(),
          "attribute_equals" => %{
            "check_slug" => slug,
            "to_status" => "healthy"
          }
        }
      },
      group_by: ["check_slug", "target_key"],
      threshold: threshold,
      window_seconds: window_seconds,
      bucket_seconds: bucket_seconds,
      cooldown_seconds: cooldown_seconds,
      renotify_seconds: renotify_seconds,
      event: %{
        "log_name" => "alert.declarative_check.#{slug}",
        "message" => "Declarative check #{name} transitioned to unhealthy verdict"
      },
      alert: %{
        "title" => "#{name} unhealthy",
        "severity" => severity
      }
    }
  end

  @doc """
  Upserts or disables the `StatefulAlertRule` corresponding to `check`.
  """
  @spec reconcile(map(), keyword()) :: :ok | {:error, term()}
  def reconcile(check, opts \\ []) when is_map(check) and is_list(opts) do
    attrs = build_rule_attrs(check)

    case Keyword.get(opts, :rule_writer) do
      writer when is_function(writer, 1) ->
        writer.(attrs)

      _ ->
        upsert_stateful_rule(attrs)
    end
  rescue
    error ->
      Logger.warning("Declarative check stateful alert rule sync failed",
        rule_name: rule_name(to_string(Map.get(check, :slug) || Map.get(check, "slug") || "")),
        reason: Exception.message(error)
      )

      :ok
  end

  @doc """
  Removes the `StatefulAlertRule` owned by `slug` when a check is deleted.
  """
  @spec delete_for_slug(String.t(), keyword()) :: :ok
  def delete_for_slug(slug, opts \\ []) when is_binary(slug) and is_list(opts) do
    rname = rule_name(slug)

    case Keyword.get(opts, :rule_deleter) do
      deleter when is_function(deleter, 1) ->
        deleter.(rname)
        :ok

      _ ->
        query =
          StatefulAlertRule
          |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
          |> Ash.Query.filter(name == ^rname)

        case Ash.read_one(query, actor: @system_actor, domain: ServiceRadar.Observability) do
          {:ok, nil} ->
            :ok

          {:ok, rule} ->
            _ = Ash.destroy(rule, actor: @system_actor, domain: ServiceRadar.Observability)
            :ok

          {:error, reason} ->
            Logger.warning("Failed to load declarative check alert rule for deletion",
              rule_name: rname,
              reason: inspect(reason)
            )

            :ok
        end
    end
  rescue
    _ -> :ok
  end

  defp upsert_stateful_rule(attrs) do
    rname = attrs.name

    query =
      StatefulAlertRule
      |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
      |> Ash.Query.filter(name == ^rname)

    case Ash.read_one(query, actor: @system_actor, domain: ServiceRadar.Observability) do
      {:ok, nil} ->
        if attrs.enabled do
          StatefulAlertRule
          |> Ash.Changeset.for_create(:create, attrs, actor: @system_actor)
          |> Ash.create(actor: @system_actor, domain: ServiceRadar.Observability)
          |> normalize_write_result(rname)
        else
          :ok
        end

      {:ok, existing} ->
        existing
        |> Ash.Changeset.for_update(:update, attrs, actor: @system_actor)
        |> Ash.update(actor: @system_actor, domain: ServiceRadar.Observability)
        |> normalize_write_result(rname)

      {:error, reason} ->
        Logger.warning("Failed to query declarative check stateful alert rule",
          rule_name: rname,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp normalize_write_result({:ok, _}, _rname), do: :ok

  defp normalize_write_result({:error, reason} = err, rname) do
    Logger.warning("Failed to persist declarative check stateful alert rule",
      rule_name: rname,
      reason: inspect(reason)
    )

    err
  end

  defp fetch_val(map, str_key, default) when is_map(map) do
    atom_key =
      try do
        String.to_existing_atom(str_key)
      rescue
        ArgumentError -> nil
      end

    cond do
      Map.has_key?(map, str_key) -> Map.get(map, str_key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
      true -> default
    end
  end

  defp clamp_int(val, min_v, max_v) when is_integer(val), do: val |> max(min_v) |> min(max_v)
  defp clamp_int(_, min_v, _max_v), do: min_v
end
