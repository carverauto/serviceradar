defmodule ServiceradarConfig.TestPaths do
  @moduledoc """
  Locates declared build inputs from an ExUnit run.

  `rules_elixir`'s `ex_unit_test` copies every `srcs` and `data` file to
  `${TEST_TMPDIR}/<workspace-relative path>` and cds to `${TEST_TMPDIR}/<package>`, so the staged
  tree mirrors the workspace. Naming an input against that tree needs no repository name.

  An earlier version reached into `TEST_SRCDIR` and tried `_main` then `serviceradar` in turn --
  guessing the canonical and apparent repository names, and working only because the runfiles
  tree happens to carry the same files.

  There is deliberately no environment override: a variable that can repoint an input lets a run
  read files nothing in the build graph knows about.
  """

  def data!(relative) do
    tmpdir =
      System.get_env("TEST_TMPDIR") || raise "TEST_TMPDIR unset: this test's inputs are staged"

    path = Path.join(tmpdir, relative)

    if File.exists?(path) do
      path
    else
      raise "cannot locate #{relative} at #{path}; add it to the target's srcs or data"
    end
  end

  def decode!(relative, module) do
    relative |> data!() |> File.read!() |> then(&module.decode/1)
  end
end
