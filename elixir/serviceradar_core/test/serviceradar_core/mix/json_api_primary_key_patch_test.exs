defmodule ServiceRadarCore.Mix.JsonApiPrimaryKeyPatchTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCore.Mix.JsonApiPrimaryKeyPatch

  @moduletag :db_free

  test "targets the compiling project's deps after chdir into a path dependency" do
    parent = Path.join(System.tmp_dir!(), "sr-mix-root-#{System.unique_integer([:positive])}")
    child = Path.join(parent, "serviceradar_core")
    File.mkdir_p!(child)

    File.write!(Path.join(parent, "mix.exs"), """
    defmodule SrOuterMix.MixProject do
      use Mix.Project

      def project, do: [app: :sr_outer_mix, version: "0.0.0"]
    end
    """)

    Mix.Project.in_project(:sr_outer_mix, parent, [], fn _module ->
      cwd = File.cwd!()
      deps_env = System.get_env("MIX_DEPS_PATH")
      System.delete_env("MIX_DEPS_PATH")

      try do
        File.cd!(child)

        parent_deps =
          Path.expand("deps/ash_json_api", Path.dirname(Mix.Project.project_file()))

        assert JsonApiPrimaryKeyPatch.target_root() == parent_deps
        refute JsonApiPrimaryKeyPatch.target_root() == Path.expand("deps/ash_json_api")
      after
        File.cd!(cwd)

        if deps_env do
          System.put_env("MIX_DEPS_PATH", deps_env)
        else
          System.delete_env("MIX_DEPS_PATH")
        end
      end
    end)
  end

  test "serviceradar_core manifest loads when the patcher is not staged" do
    dir = Path.join(System.tmp_dir!(), "sr-mix-manifest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!(Path.expand("../../../mix.exs", __DIR__), Path.join(dir, "mix.exs"))

    script = """
    Application.ensure_all_started(:mix)
    Code.compile_file("mix.exs")
    """

    {output, status} = System.cmd("elixir", ["-e", script], cd: dir, stderr_to_stdout: true)

    assert status == 0, output
  end
end
