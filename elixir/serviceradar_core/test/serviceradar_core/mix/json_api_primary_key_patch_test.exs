defmodule ServiceRadarCore.Mix.JsonApiPrimaryKeyPatchTest do
  use ExUnit.Case, async: false

  alias ServiceRadarCore.Mix.JsonApiPrimaryKeyPatch

  @moduletag :db_free

  test "patches ash_json_api in the mix project compiling dependencies" do
    parent = Path.join(System.tmp_dir!(), "sr-mix-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(parent)
    core_deps = Path.join(Mix.Project.deps_path(), "ash_json_api")

    File.write!(Path.join(parent, "mix.exs"), """
    defmodule SrOuterMix.MixProject do
      use Mix.Project

      def project, do: [app: :sr_outer_mix, version: "0.0.0"]
    end
    """)

    Mix.Project.in_project(:sr_outer_mix, parent, [], fn _module ->
      assert JsonApiPrimaryKeyPatch.target_root() ==
               Path.join(Mix.Project.deps_path(), "ash_json_api")

      refute JsonApiPrimaryKeyPatch.target_root() == core_deps
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
