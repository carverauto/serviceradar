# Format generated Elixir files in place exactly as `mix format` formats them in the
# owning Mix project, so a committed copy kept current by a `write_source_files` diff test
# is already what the pre-commit `mix format` hook would write.
#
# Usage:
#   elixir format_generated_elixir.exs <project .formatter.exs> <app=dep_dir>... -- <file>...
#
# Each <app=dep_dir> names a dependency directory that holds the dependency's own
# .formatter.exs, which is what `import_deps` reads. Formatter plugins (Styler,
# Spark.Formatter) must already be on the code path through ERL_LIBS. Everything else is
# Mix's own resolution: `Mix.Tasks.Format.formatter_for_file/2` applies the same
# `import_deps`, `locals_without_parens` and plugin chain that `mix format <file>` does.
Mix.start()

{config_args, files} =
  case Enum.split_while(System.argv(), &(&1 != "--")) do
    {config_args, ["--" | files]} -> {config_args, files}
    _ -> raise "Expected `<project .formatter.exs> <app=dep_dir>... -- <file>...`"
  end

[dot_formatter | dep_args] = config_args

deps_paths =
  Map.new(dep_args, fn arg ->
    [app, dir] = String.split(arg, "=", parts: 2)
    {String.to_atom(app), Path.expand(dir)}
  end)

dot_formatter = Path.expand(dot_formatter)

options = [
  root: Path.dirname(dot_formatter),
  dot_formatter: dot_formatter,
  deps_paths: deps_paths,
  # Plugins are loaded from ERL_LIBS; there is no Mix project to run `loadpaths` for.
  plugin_loader: & &1
]

# One pass is not always enough: on raw AshPostgres output the formatter can produce text that a
# second pass rewrites again (a multi-line `drop constraint(...)` call, for one). The pre-commit
# hook applies one pass to the committed file, so the committed file must be a fixed point.
defmodule FormatGeneratedElixir do
  @max_passes 5

  def to_fixed_point(formatter, file, source, pass \\ 1)

  def to_fixed_point(_formatter, file, _source, pass) when pass > @max_passes do
    raise "#{file}: mix format did not reach a fixed point in #{@max_passes} passes"
  end

  def to_fixed_point(formatter, file, source, pass) do
    case formatter.(source) do
      ^source -> source
      formatted -> to_fixed_point(formatter, file, formatted, pass + 1)
    end
  end
end

for file <- files do
  file = Path.expand(file)
  {formatter, _opts} = Mix.Tasks.Format.formatter_for_file(file, options)
  File.write!(file, FormatGeneratedElixir.to_fixed_point(formatter, file, File.read!(file)))
end
