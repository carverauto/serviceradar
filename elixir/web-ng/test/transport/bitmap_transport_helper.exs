support = ~w(bitmap_fixture bitmap_channel bitmap_socket bitmap_endpoint bitmap_server)
beams = Enum.flat_map(support, &Code.compile_file(Path.join(__DIR__, &1 <> ".exs")))
:persistent_term.put(:bitmap_transport_support, beams)
{:ok, _} = Application.ensure_all_started(:gun)
ExUnit.start(max_cases: 1)

ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
  if total - excluded - skipped == 0 do
    IO.puts(:stderr, "FAILED: the bitmap transport target executed ZERO tests")
    System.at_exit(fn _ -> System.halt(1) end)
  end
end)
