defmodule ServiceRadarWebNG.Test.LaneCoverageGuard do
  @moduledoc """
  Fails the database-free web-ng lane when a test is invisible to every CI lane.

  web-ng routes every test through exactly one of three tags:

    * `:db_free` -- runs under `//elixir/web-ng:unit_tests` (the allow-list tier:
      every test is excluded and only this tag re-includes it);
    * `:web_ng_shared_fixture_db` -- runs under `//elixir/web-ng:networks_live_db_test`;
    * `:topology_atlas_db` -- runs under `//elixir/web-ng:topology_atlas_db_test`.

  A test carrying none of them is excluded by the first lane and never loaded by
  the other two (each declares an explicit `srcs` list), so it can rot
  indefinitely while every lane stays green. That is issue #4797: roughly 40% of
  web-ng test files were selected by no lane at all, and the failures they had
  accumulated were only discovered by running them by hand.

  This formatter is registered by `test/test_helper.exs` only in the
  database-free configuration. That lane loads every test file, and a formatter
  receives a `test_finished` event -- tags included -- for every test it EXCLUDES
  just as for every test it runs. A test that is excluded here and carries no
  other lane tag is therefore unrouted by construction, whatever `describe`
  nesting or per-test tagging produced it.

  The check is deliberately per-test rather than per-file: a single
  `@tag :db_free` at the top of a file keeps the guard quiet for that one test
  while 37 siblings stay invisible. Only tagging each test (or its module, when
  the whole module shares a lane) satisfies it.
  """

  use GenServer

  @lane_tags [:db_free, :web_ng_shared_fixture_db, :topology_atlas_db]

  defstruct unrouted: []

  def init(_opts), do: {:ok, %__MODULE__{}}

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    if unrouted?(test), do: {:noreply, %{state | unrouted: [test | state.unrouted]}}, else: {:noreply, state}
  end

  def handle_cast({:suite_finished, _run_us}, state) do
    enforce!(Enum.reverse(state.unrouted))
    {:noreply, state}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  defp unrouted?(%ExUnit.Test{state: state, tags: tags}) do
    case state do
      nil -> false
      {:excluded, _} -> not Enum.any?(@lane_tags, &Map.has_key?(tags, &1))
      {:skipped, _} -> not Enum.any?(@lane_tags, &Map.has_key?(tags, &1))
      _ -> false
    end
  end

  defp enforce!([]) do
    :ok
  end

  defp enforce!(unrouted) do
    entries =
      Enum.map_join(unrouted, "\n", fn test ->
        "  #{test.tags[:file]}:#{test.tags[:line]}  #{inspect(test.module)} #{test.name}"
      end)

    IO.puts(:stderr, """

    FAILED: #{length(unrouted)} test(s) are routed to no CI lane.

    Every web-ng test must carry exactly one lane tag so some lane selects it:
      @moduletag :db_free                      -- needs no database; runs in //elixir/web-ng:unit_tests
      @moduletag :web_ng_shared_fixture_db     -- needs the shared fixture; runs in //elixir/web-ng:networks_live_db_test
                                                 (the file must also be added to that target's srcs and to
                                                 build/contracts/web_ng_db_runner_contract_test.py)
      @moduletag :topology_atlas_db            -- runs in //elixir/web-ng:topology_atlas_db_test

    Unrouted (excluded here, tagged for no other lane):
    #{entries}
    """)

    System.at_exit(fn _ -> System.halt(1) end)
  end
end
