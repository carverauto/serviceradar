defmodule Mix.Tasks.Serviceradar.Openapi.Dump do
  @shortdoc "Dump the AshJsonApi OpenAPI spec to a committed JSON file"

  @moduledoc """
  Renders `ServiceRadarWebNGWeb.AshJsonApiRouter.spec/0` to a committed file
  for external consumers such as the developer portal. Paths in this artifact
  are relative to `/api/v2`.

  The live document is generated separately by
  `ServiceRadarWebNGWeb.Api.OpenApiV2Controller`; its paths include `/api/v2`.
  Rendering uses compiled resource DSL without starting the application or
  connecting to a database. Use `--check` to detect committed artifact drift.

  ## Usage

      # (re)generate priv/static/openapi.json
      mix serviceradar.openapi.dump

      # verify the committed file is up to date; exits non-zero on drift
      mix serviceradar.openapi.dump --check

  ## Options

    * `--check` - do not write; compare the freshly generated spec against the
      committed file and exit non-zero (with a diff hint) if they differ.
    * `--path PATH` - override the output path
      (default: `priv/static/openapi.json`, relative to the web-ng project root).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]
  use Mix.Task

  @default_relative_path "priv/static/openapi.json"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [check: :boolean, path: :string])

    # Compile the project so the router + Ash resources are loadable. We do NOT
    # start the application: the spec is built entirely from compiled DSL, so no
    # DB/network is touched.
    Mix.Task.run("compile")
    Code.ensure_loaded!(ServiceRadarWebNGWeb.AshJsonApiRouter)

    json = generate_json()
    path = output_path(opts)

    if opts[:check] do
      check(path, json)
    else
      write(path, json)
    end
  end

  defp generate_json do
    ServiceRadarWebNGWeb.AshJsonApiRouter.spec()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp output_path(opts) do
    opts
    |> Keyword.get(:path, @default_relative_path)
    |> Path.expand(File.cwd!())
  end

  defp write(path, json) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, json)
    Mix.shell().info("Wrote OpenAPI spec to #{Path.relative_to_cwd(path)} (#{byte_size(json)} bytes)")
  end

  defp check(path, json) do
    committed =
      case File.read(path) do
        {:ok, contents} ->
          contents

        {:error, reason} ->
          Mix.raise("""
          Could not read #{Path.relative_to_cwd(path)} (#{:file.format_error(reason)}).
          Run `mix serviceradar.openapi.dump` and commit the result.
          """)
      end

    if committed == json do
      Mix.shell().info("OpenAPI spec #{Path.relative_to_cwd(path)} is up to date.")
    else
      Mix.raise("""
      OpenAPI spec #{Path.relative_to_cwd(path)} is out of date.
      Regenerate it and commit the result:

          (cd elixir/web-ng && mix serviceradar.openapi.dump)
      """)
    end
  end
end
