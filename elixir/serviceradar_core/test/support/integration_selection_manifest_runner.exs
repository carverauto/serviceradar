defmodule ServiceRadar.IntegrationSelectionManifestRunner do
  @moduledoc false

  alias ServiceRadar.IntegrationSelectionManifest

  @identity_prefix "SERVICERADAR_SELECTION_IDENTITY|"
  @sources_env "SERVICERADAR_SELECTION_SOURCES"
  @database_env ~w(
    DATABASE_URL
    PG_DATABASE_URL
    SRQL_TEST_DATABASE_URL
    SERVICERADAR_TEST_DATABASE_URL
    SRQL_TEST_DATABASE_URL_FILE
    SERVICERADAR_TEST_DATABASE_URL_FILE
  )

  def install! do
    reject_database_configuration!()
    ExUnit.start(autorun: false)
    require_sources!()
    emit!()
  end

  defp emit! do
    reject_database_configuration!()
    reject_started_application!()
    source_root = File.cwd!()

    source_root
    |> loaded_test_modules()
    |> IntegrationSelectionManifest.selected_source_test_identities(source_root)
    |> Enum.sort()
    |> Enum.each(fn {source, module, test_name} ->
      if !is_atom(test_name) do
        raise ArgumentError, "integration test name must be an atom: #{inspect(test_name)}"
      end

      components = [source, inspect(module), Atom.to_string(test_name)]
      identity = Enum.map_join(components, "|", &Base.url_encode64(&1, padding: false))
      IO.puts(@identity_prefix <> identity)
    end)
  end

  defp loaded_test_modules(source_root) do
    Enum.flat_map(:code.all_loaded(), fn {module, _beam_path} ->
      if function_exported?(module, :__ex_unit__, 0) and
           function_exported?(module, :__ex_unit__, 1) do
        test_module = module.__ex_unit__()

        if inside_source_root?(test_module.file, source_root) do
          [{test_module, module.__ex_unit__(:config)}]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp require_sources! do
    sources =
      @sources_env
      |> System.fetch_env!()
      |> String.split(",", trim: true)

    if sources == [] do
      raise "#{@sources_env} must contain at least one declared test source"
    end

    case Kernel.ParallelCompiler.require(sources,
           max_concurrency: min(System.schedulers_online(), 4),
           return_diagnostics: true
         ) do
      {:ok, _modules, _warnings} ->
        :ok

      {:error, errors, _warnings} ->
        raise "could not load integration selection sources: #{inspect(errors, pretty: true)}"
    end
  end

  defp inside_source_root?(file, source_root) do
    relative = file |> Path.expand(source_root) |> Path.relative_to(source_root)
    relative != ".." and not String.starts_with?(relative, "../")
  end

  defp reject_database_configuration! do
    configured = Enum.filter(@database_env, &(String.trim(System.get_env(&1) || "") != ""))

    if configured != [] do
      raise "integration selection must be database-free; configured variables: #{inspect(configured)}"
    end
  end

  defp reject_started_application! do
    if Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
         app == :serviceradar_core
       end) do
      raise "integration selection must not start the ServiceRadar application"
    end
  end
end

ServiceRadar.IntegrationSelectionManifestRunner.install!()
