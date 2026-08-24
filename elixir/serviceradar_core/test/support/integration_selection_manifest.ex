defmodule ServiceRadar.IntegrationSelectionManifest do
  @moduledoc false

  @include [:integration, :requires_app]
  @exclude [:test, :external, :cluster, :large_ingestion, :benchmark]

  @type test_identity :: {String.t(), module(), atom()}

  @spec selected_source_test_identities(
          [
            {ExUnit.TestModule.t(), %{required(:async?) => boolean(), required(:group) => term()}}
          ],
          Path.t()
        ) :: MapSet.t(test_identity())
  def selected_source_test_identities(test_modules, source_root) do
    source_root = Path.expand(source_root)
    {include, exclude} = ExUnit.Filters.normalize(@include, @exclude)

    Enum.reduce(test_modules, MapSet.new(), fn {test_module, config}, selected ->
      source = relative_source!(test_module.file, source_root)

      Enum.reduce(test_module.tests, selected, fn test, identities ->
        if selected_test?(test, test_module, config, include, exclude) do
          MapSet.put(identities, {source, test.module, test.name})
        else
          identities
        end
      end)
    end)
  end

  @spec selected_source_modules(
          [
            {ExUnit.TestModule.t(), %{required(:async?) => boolean(), required(:group) => term()}}
          ],
          Path.t()
        ) :: MapSet.t({String.t(), module()})
  def selected_source_modules(test_modules, source_root) do
    test_modules
    |> selected_source_test_identities(source_root)
    |> MapSet.new(fn {source, module, _test_name} -> {source, module} end)
  end

  defp selected_test?(test, test_module, config, include, exclude) do
    tags =
      Map.merge(test.tags, %{
        test: test.name,
        module: test.module,
        async: Map.fetch!(config, :async?),
        test_group: Map.fetch!(config, :group)
      })

    case ExUnit.Filters.eval(include, exclude, tags, test_module.tests) do
      :ok -> true
      {:skipped, _reason} -> true
      {:excluded, _reason} -> false
    end
  end

  defp relative_source!(file, source_root) do
    source =
      file
      |> Path.expand(source_root)
      |> Path.relative_to(source_root)

    if source == ".." or String.starts_with?(source, "../") do
      raise ArgumentError,
            "ExUnit source #{inspect(file)} is outside selection root #{inspect(source_root)}"
    end

    source
  end
end
