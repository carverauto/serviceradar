Application.ensure_all_started(:telemetry)

# An interrupted ExUnit run must fail, not pass: SIGTERM otherwise shuts the
# BEAM down gracefully with exit 0 (see test/test_helper.exs).
case System.trap_signal(:sigterm, fn ->
       IO.puts(:stderr, "SIGTERM received before ExUnit completed; failing the run")
       System.halt(1)
     end) do
  {:ok, _id} -> :ok
  {:error, :not_sup} -> :ok
end

ExUnit.start()
