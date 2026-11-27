# Bazel evaluates this file with `elixir -r` and does not load Mix
# dependencies. Plug.Conn and StreamData fetch their application env.
for app <- [:plug, :stream_data] do
  case Application.load(app) do
    :ok -> :ok
    {:error, {:already_loaded, ^app}} -> :ok
  end
end

# rules_elixir's compiled .app can omit the Mix application env, so set the
# keys those libraries fetch. The values are the libraries' own defaults.
Application.put_env(:plug, :validate_header_keys_during_test, true)
Application.put_env(:stream_data, :initial_size, 1)
Application.put_env(:stream_data, :max_runs, 100)
Application.put_env(:stream_data, :max_run_time, :infinity)
Application.put_env(:stream_data, :max_shrinking_steps, 100)
Application.put_env(:stream_data, :inspect_opts, [])

ExUnit.start()
