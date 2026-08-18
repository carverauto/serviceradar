defmodule ServiceradarConfig.TestPaths do
  @moduledoc """
  Locates declared build inputs from an ExUnit run.

  Bazel runs the test out of a runfiles tree, where a bare relative path resolves to nothing.
  There is deliberately no environment override: a variable that can repoint an input lets a
  run read files nothing in the build graph knows about.
  """

  def data!(relative) do
    srcdir = System.get_env("TEST_SRCDIR") || raise "TEST_SRCDIR unset: this test needs runfiles"

    ["_main", "serviceradar"]
    |> Enum.map(&Path.join([srcdir, &1, relative]))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> raise "cannot locate #{relative} under #{srcdir}"
      path -> path
    end
  end

  def decode!(relative, module) do
    relative |> data!() |> File.read!() |> then(&module.decode/1)
  end
end
