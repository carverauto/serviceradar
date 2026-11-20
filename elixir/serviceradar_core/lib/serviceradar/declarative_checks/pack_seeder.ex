defmodule ServiceRadar.DeclarativeChecks.PackSeeder do
  @moduledoc """
  Installs the Solution Packs that every deployment carries, on coordinator
  startup, from the pack files under `priv/solution_packs/`.

  The pack files are the only definition of these checks, rules and dashboards.
  The seeder hands them to `ServiceRadar.Catalog.Reconciler`, the same path a
  catalog install takes, so a seeded pack and an operator-installed pack are the
  same thing: one `InstalledSolutionPack`, managed resources, and upgrades that
  keep operator `parameter_overrides`, paused rules and diverged resources.

  The seeder never moves a pack backwards. It installs a pack that is absent,
  upgrades one that is older than the shipped files, re-applies its own install
  at the same version, and otherwise leaves the installed pack alone: an
  operator who installed a newer release from a catalog keeps it.
  """

  use ServiceRadar.DelayedSeeder, delay_ms: 8_000, callback: :seed_all

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.BuiltinPacks
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.DeclarativeCheck

  require Logger

  @seeded_pack_slugs ["storage-and-nvr-health"]

  # Checks an earlier seeder created under a slug the pack files never used.
  # The pack ships the same check under another slug, so the old one is retired.
  @retired_check_slugs %{
    "io.serviceradar.storage-and-nvr-health" => ["storage-archive-credential-and-usage-health"]
  }

  # Parameter names the earlier seeder used, and the pack parameter each became.
  @renamed_parameters %{
    "warn_percent" => "utilization_warn_pct",
    "crit_percent" => "utilization_crit_pct",
    "warn_share_percent" => "hold_warn_share_pct",
    "crit_share_percent" => "hold_crit_share_pct"
  }

  @spec seed_all() :: :ok
  def seed_all do
    if repo_enabled?() do
      seed_builtin_packs()
    end

    :ok
  end

  @doc """
  Installs or upgrades every seeded pack. Returns one result per pack:
  `%{slug:, action: :installed | :upgraded | :reapplied | :kept_installed | :error}`.
  """
  @spec seed_builtin_packs(keyword()) :: {:ok, [map()]}
  def seed_builtin_packs(opts \\ []) when is_list(opts) do
    opts = Keyword.put_new(opts, :actor, SystemActor.system(:declarative_check_pack_seeder))
    {:ok, Enum.map(@seeded_pack_slugs, &seed_pack(&1, opts))}
  end

  defp seed_pack(slug, opts) do
    with {:ok, pack} <- BuiltinPacks.get_pack(slug),
         pack_id = pack.manifest["id"],
         action when action != :kept_installed <-
           seed_action(Reconciler.installed_pack(pack_id, opts), pack.manifest["version"]),
         params = %{
           "source" => %{"source_type" => "builtin"},
           "config" => carried_config(existing_checks(pack, action, opts))
         },
         {:ok, _result} <- Reconciler.reconcile(pack, params, opts) do
      retire_replaced_checks(pack_id, opts)
      %{slug: slug, action: action}
    else
      :kept_installed ->
        %{slug: slug, action: :kept_installed}

      {:error, reason} ->
        Logger.warning("failed to seed built-in solution pack",
          pack_slug: slug,
          reason: inspect(reason)
        )

        %{slug: slug, action: :error, reason: reason}
    end
  end

  @doc """
  What the seeder does about a pack, given what is installed (`nil` when
  nothing is) and the version of the shipped pack files.
  """
  @spec seed_action(map() | nil, String.t()) ::
          :installed | :upgraded | :reapplied | :kept_installed
  def seed_action(nil, _shipped_version), do: :installed

  def seed_action(installed, shipped_version) do
    installed_version = to_string(Map.get(installed, :pack_version))
    source = Map.get(installed, :source_type)

    case compare_versions(installed_version, shipped_version) do
      :lt -> :upgraded
      :eq when source in [:builtin, "builtin"] -> :reapplied
      _ -> :kept_installed
    end
  end

  # An unparseable installed version is not a reason to overwrite an install.
  defp compare_versions(installed, shipped) do
    with {:ok, a} <- Version.parse(installed),
         {:ok, b} <- Version.parse(shipped) do
      Version.compare(a, b)
    else
      _ -> :gt
    end
  end

  @doc """
  Pack configuration that keeps the thresholds an operator tuned on checks the
  earlier seeder created, under the parameter names the pack uses.
  """
  @spec carried_config([map()]) :: map()
  def carried_config(checks) do
    for check <- checks,
        {name, value} <- Map.get(check, :parameter_overrides) || %{},
        into: %{} do
      name = to_string(name)
      {Map.get(@renamed_parameters, name, name), value}
    end
  end

  # Only a first install adopts checks that predate the pack record. After
  # that the installed pack's own configuration is the record of tuning.
  defp existing_checks(pack, :installed, opts) do
    if Keyword.has_key?(opts, :state_store) do
      []
    else
      actor = Keyword.fetch!(opts, :actor)
      retired = Map.get(@retired_check_slugs, pack.manifest["id"], [])

      for slug <- Enum.map(pack.checks, & &1.normalized["slug"]) ++ retired,
          {:ok, %DeclarativeCheck{} = check} <- [DeclarativeCheck.get_by_slug(slug, actor: actor)] do
        check
      end
    end
  end

  defp existing_checks(_pack, _action, _opts), do: []

  @doc """
  Whether a check left by an earlier seeder may be removed: it is still managed
  by `pack_id` and nobody has edited it since it was stamped.
  """
  @spec retirable?(map(), String.t()) :: boolean()
  def retirable?(check, pack_id) do
    Map.get(check, :managed) == true and Map.get(check, :pack_id) == pack_id and
      Map.get(check, :template_fingerprint) == CanonicalJSON.template_fingerprint(check)
  end

  defp retire_replaced_checks(pack_id, opts) do
    if Keyword.has_key?(opts, :state_store) do
      :ok
    else
      actor = Keyword.fetch!(opts, :actor)

      for slug <- Map.get(@retired_check_slugs, pack_id, []),
          {:ok, %DeclarativeCheck{} = check} <- [DeclarativeCheck.get_by_slug(slug, actor: actor)] do
        retire_check(check, pack_id, actor)
      end

      :ok
    end
  end

  defp retire_check(check, pack_id, actor) do
    if retirable?(check, pack_id) do
      case Ash.destroy(check, actor: actor) do
        :ok ->
          Logger.info("retired a check replaced by its solution pack", rule_name: check.slug)

        {:error, reason} ->
          Logger.warning("failed to retire a replaced check",
            rule_name: check.slug,
            reason: inspect(reason)
          )
      end
    else
      Logger.warning("left a replaced check in place because it was edited or detached",
        rule_name: check.slug
      )
    end
  end
end
