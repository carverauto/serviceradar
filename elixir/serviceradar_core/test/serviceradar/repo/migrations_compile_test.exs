defmodule ServiceRadar.Repo.MigrationsCompileTest do
  @moduledoc """
  Every migration module must compile.

  This exists because a migration that does not compile takes down the ENTIRE migration
  run, not just itself: `Ecto.Migrator` compiles every module in the directory before
  executing any of them, so one bad file means `mix ash.migrate` exits having applied zero
  migrations. A fresh install cannot provision a database and an existing deployment cannot
  upgrade.

  That shipped. `20260721123000_add_direct_leaf_access_metadata` called `add/1` three times
  (`Ecto.Migration` defines `add/2` and `add/3`; there is no `add/1`), reached staging, and
  was found only by someone running migrations by hand for an unrelated reason.

  Nothing was watching. `mix test` and `bazel test //...` never compile migrations -- they
  are staged as `data`, which puts them on disk without building them. The target that does
  compile and run them, `//elixir/serviceradar_core:migrate_template`, is tagged `manual`
  precisely so tag selection cannot pull it into a batch: it is an ordered DDL step in the
  //rust/integration-db fixture lifecycle and needs a live database. So `//...` never
  expands it, and a syntactically-parseable but uncompilable migration had no gate at all.

  Compilation is the right granularity for the unit tier: it needs no database, no fixture
  lifecycle and no ordering, and it catches the whole class -- undefined functions, bad
  arities, unknown aliases, macro misuse -- that a parse-only check would miss. `add/1` is
  an "undefined function" error, which only surfaces when the module is actually compiled,
  so `Code.string_to_quoted/1` would have reported this file as fine.

  Executing the migrations still belongs to the integration tier; this only proves they
  *can* be executed.
  """

  use ExUnit.Case, async: false

  @migrations_dir Path.expand("../../../priv/repo/migrations", __DIR__)

  test "every migration in priv/repo/migrations compiles" do
    files = Path.wildcard(Path.join(@migrations_dir, "*.exs"))

    # A vacuous pass here would be worse than no test: it would report success for a
    # directory the runfiles never staged.
    assert length(files) > 100,
           "expected the migrations directory to be staged, found #{length(files)} file(s) " <>
             "under #{@migrations_dir}"

    # Kernel.ParallelCompiler is what Ecto.Migrator itself uses, so this reproduces the
    # failure mode exactly rather than approximating it. Compiling defines each module; that
    # runs module bodies and attributes but NOT up/0 or down/0, so no database is touched.
    {result, diagnostics} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        Kernel.ParallelCompiler.compile(files)
      end)

    case result do
      {:ok, modules, _warnings} ->
        # Purge what we just defined so a later test that loads a migration by hand sees a
        # clean slate rather than our copy.
        Enum.each(modules, fn module ->
          :code.purge(module)
          :code.delete(module)
        end)

        assert modules != []

      {:error, errors, _warnings} ->
        detail =
          Enum.map_join(errors, "\n", fn
            %{file: file, message: message, position: position} ->
              "  #{Path.basename(file)}:#{inspect(position)}: #{message}"

            other ->
              "  #{inspect(other)}"
          end)

        flunk("""
        #{length(errors)} migration(s) failed to compile.

        Ecto compiles every migration before running any, so this blocks the whole
        migration run -- fresh installs cannot provision and upgrades cannot proceed.

        #{detail}

        Compiler output:
        #{diagnostics}
        """)
    end
  end
end
