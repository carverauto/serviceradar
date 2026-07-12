defmodule ServiceRadar.Observability.PluginResultRepairAssignmentSupport do
  @moduledoc false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.Plugin
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  @doc false
  def create_repair_assignment!(status) do
    name = String.trim(status.service_name)
    package = create_repair_package!(name)

    create_repair_assignment_for_package!(status, package)
  end

  @doc false
  def create_repair_assignment_for_package!(status, package, opts \\ []) do
    actor = SystemActor.system(:plugin_result_repair_test)

    assignment_changeset =
      Ash.Changeset.for_create(
        PluginAssignment,
        :create,
        %{
          agent_uid: String.trim(status.agent_id),
          plugin_package_id: package.id,
          enabled: Keyword.get(opts, :enabled, true)
        },
        actor: actor
      )

    create_without_notifications!(assignment_changeset)
  end

  @doc false
  def create_repair_package!(name, opts \\ []) do
    actor = SystemActor.system(:plugin_result_repair_test)

    plugin_id =
      Keyword.get(opts, :plugin_id, "plugin-result-repair-#{System.unique_integer([:positive])}")

    version = Keyword.get(opts, :version, "1.0.0")

    if Keyword.get(opts, :create_plugin?, true) do
      Plugin
      |> Ash.Changeset.for_create(:create, %{plugin_id: plugin_id, name: name}, actor: actor)
      |> Ash.create!(domain: ServiceRadar.Plugins)
    end

    manifest = %{
      "id" => plugin_id,
      "name" => name,
      "version" => version,
      "entrypoint" => "run_check",
      "runtime" => "wasi-preview1",
      "outputs" => "serviceradar.plugin_result.v1",
      "capabilities" => ["submit_result"],
      "resources" => %{
        "requested_memory_mb" => 32,
        "requested_cpu_ms" => 100,
        "max_open_connections" => 1
      }
    }

    package_changeset =
      Ash.Changeset.for_create(
        PluginPackage,
        :create,
        %{
          plugin_id: plugin_id,
          name: name,
          version: version,
          entrypoint: "run_check",
          runtime: "wasi-preview1",
          outputs: "serviceradar.plugin_result.v1",
          manifest: manifest,
          content_hash: "sha256:#{plugin_id}-#{version}",
          source_type: :upload
        },
        actor: actor
      )

    package = create_without_notifications!(package_changeset)

    package =
      package
      |> Ash.Changeset.for_update(:approve, %{approved_by: "test"}, actor: actor)
      |> update_without_notifications!()

    package
  end

  defp create_without_notifications!(changeset) do
    case Ash.create(changeset,
           domain: ServiceRadar.Plugins,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp update_without_notifications!(changeset) do
    case Ash.update(changeset,
           domain: ServiceRadar.Plugins,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end
end
