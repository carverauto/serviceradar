defmodule ServiceRadar.Observability.ZenRuleSeeder do
  @moduledoc """
  Seeds default Zen rules on startup.

  In single-deployment architecture, the DB connection's
  search_path determines which schema rules are seeded into.
  """

  use ServiceRadar.DelayedSeeder, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.ZenRule
  alias ServiceRadar.Observability.ZenRuleSync
  alias ServiceRadar.Observability.ZenRuleTemplates

  require Ash.Query
  require Logger

  def seed_all do
    if repo_enabled?() do
      # DB connection's search_path determines the schema
      seed_rules()
    end
  end

  defp seed_rules do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:zen_rule_seeder)
    opts = [actor: actor, context: %{skip_zen_sync: true}]

    if ensure_defaults(default_zen_rules(), opts) do
      ZenRuleSync.reconcile()
    end

    :ok
  end

  defp ensure_defaults(defaults, opts) do
    query =
      ZenRule
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.select([
        :id,
        :name,
        :description,
        :enabled,
        :order,
        :subject,
        :template,
        :builder_config,
        :jdm_definition,
        :compiled_jdm,
        :format,
        :agent_id,
        :stream_name
      ])

    case Ash.read(query, opts) do
      {:ok, rules} ->
        existing = Map.new(rules, &{{&1.name, &1.subject}, &1})

        {existing, changed?} = rename_legacy_rules(rules, existing, opts)

        Enum.reduce(defaults, changed?, fn attrs, acc ->
          reconcile_or_create_rule(existing, attrs, opts) or acc
        end)

      {:error, reason} ->
        schema = Keyword.get(opts, :schema, "unknown")
        Logger.warning("Failed to check Zen rule defaults for #{schema}: #{inspect(reason)}")
        false
    end
  end

  defp rename_legacy_rules(rules, existing, opts) do
    Enum.reduce(rules, {existing, false}, fn rule, {acc, changed?} ->
      case rename_legacy_rule(rule, acc, opts) do
        {updated, renamed?} -> {updated, changed? or renamed?}
        updated -> {updated, changed?}
      end
    end)
  end

  defp reconcile_or_create_rule(existing, attrs, opts) do
    key = {attrs[:name], attrs[:subject]}

    case Map.get(existing, key) do
      nil ->
        create_rule(attrs, opts)

      rule ->
        reconcile_rule_if_needed(rule, attrs, opts)
    end
  end

  defp create_rule(attrs, opts) do
    changeset = Ash.Changeset.for_create(ZenRule, :create, attrs, opts)
    schema = Keyword.get(opts, :schema, "unknown")

    case Ash.create(changeset) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Failed to seed Zen rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )

        false
    end
  end

  defp rename_legacy_rule(rule, acc, opts) do
    case legacy_rule_name(rule.name) do
      nil -> {acc, false}
      new_name -> rename_rule_if_missing(rule, new_name, acc, opts)
    end
  end

  defp rename_rule_if_missing(rule, new_name, existing, opts) do
    key = {new_name, rule.subject}

    if Map.has_key?(existing, key) do
      {existing, false}
    else
      do_rename_rule(rule, new_name, key, existing, opts)
    end
  end

  defp do_rename_rule(rule, new_name, key, existing, opts) do
    changeset = Ash.Changeset.for_update(rule, :update, %{name: new_name}, opts)
    schema = Keyword.get(opts, :schema, "unknown")

    case Ash.update(changeset) do
      {:ok, _} ->
        {
          existing
          |> Map.delete({rule.name, rule.subject})
          |> Map.put(key, %{rule | name: new_name}),
          true
        }

      {:error, reason} ->
        Logger.warning("Failed to rename Zen rule #{rule.name} for #{schema}: #{inspect(reason)}")

        {existing, false}
    end
  end

  defp reconcile_rule_if_needed(rule, attrs, opts) do
    if seeded_snmp_rule?(rule, attrs) and seeded_snmp_rule_changed?(rule, attrs) do
      update_rule(rule, attrs, opts)
    else
      false
    end
  end

  defp update_rule(rule, attrs, opts) do
    schema = Keyword.get(opts, :schema, "unknown")

    changeset =
      Ash.Changeset.for_update(
        rule,
        :update,
        Map.take(attrs, [
          :description,
          :enabled,
          :order,
          :subject,
          :template,
          :builder_config,
          :stream_name,
          :agent_id
        ]),
        opts
      )

    case Ash.update(changeset) do
      {:ok, _updated} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Failed to reconcile Zen rule #{attrs[:name]} for #{schema}: #{inspect(reason)}"
        )

        false
    end
  end

  defp seeded_snmp_rule?(rule, attrs) do
    rule.name == "snmp_severity" and
      rule.subject == "logs.snmp" and
      attrs[:name] == "snmp_severity" and
      attrs[:subject] == "logs.snmp" and
      rule.template == attrs[:template] and
      normalize_builder_config(rule.builder_config) ==
        normalize_builder_config(attrs[:builder_config]) and
      not user_authored_override?(rule)
  end

  defp seeded_snmp_rule_changed?(rule, attrs) do
    {:ok, compiled} =
      ZenRuleTemplates.compile(attrs[:template], normalize_builder_config(attrs[:builder_config]))

    rule.compiled_jdm != compiled or
      rule.description != attrs[:description] or
      rule.enabled != attrs[:enabled] or
      rule.order != attrs[:order] or
      rule.stream_name != attrs[:stream_name] or
      rule.agent_id != attrs[:agent_id]
  end

  defp user_authored_override?(rule) do
    is_map(rule.jdm_definition) and map_size(rule.jdm_definition) > 0
  end

  defp normalize_builder_config(config) when is_map(config), do: config
  defp normalize_builder_config(_), do: %{}

  defp legacy_rule_name("syslog_passthrough"), do: "passthrough"
  defp legacy_rule_name("syslog_strip_full_message"), do: "strip_full_message"
  defp legacy_rule_name("syslog_cef_severity"), do: "cef_severity"
  defp legacy_rule_name(_), do: nil

  @doc false
  def default_zen_rules do
    [
      %{
        name: "passthrough",
        description: "Default (passthrough) for syslog logs.",
        subject: "logs.syslog",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for SNMP logs.",
        subject: "logs.snmp",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for OTEL logs.",
        subject: "logs.otel",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for OTEL metrics.",
        subject: "otel.metrics.raw",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal health logs.",
        subject: "logs.internal.health",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal jobs logs.",
        subject: "logs.internal.jobs",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal onboarding logs.",
        subject: "logs.internal.onboarding",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal audit logs.",
        subject: "logs.internal.audit",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "passthrough",
        description: "Default (passthrough) for internal sweep logs.",
        subject: "logs.internal.sweep",
        template: "passthrough",
        builder_config: %{},
        order: 100,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "strip_full_message",
        description: "Remove full_message from syslog payloads.",
        subject: "logs.syslog",
        template: "strip_full_message",
        builder_config: %{},
        order: 110,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "coraza_waf",
        description:
          "Normalize Coraza WAF syslog payloads into the generic WAF security signal shape.",
        subject: "logs.syslog",
        template: "coraza_waf",
        builder_config: %{},
        order: 105,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "cef_severity",
        description: "Map CEF severity values into normalized severity.",
        subject: "logs.syslog",
        template: "cef_severity",
        builder_config: %{},
        order: 120,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      },
      %{
        name: "snmp_severity",
        description: "Normalize SNMP trap severity fields.",
        subject: "logs.snmp",
        template: "snmp_severity",
        builder_config: %{},
        order: 110,
        stream_name: "events",
        agent_id: "default-agent",
        enabled: true
      }
    ]
  end
end
