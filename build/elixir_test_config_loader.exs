# Loaded before a project's test_helper.exs by //build:elixir_tests.bzl.
#
# `mix test` evaluates config/config.exs (and whatever it imports) and applies it to the
# application environment before running anything. ex_unit_test runs the files with plain
# `elixir -r`, which does none of that, so without this every Application.fetch_env!/2 for
# a value that lives in config/ raises. Two real examples:
#
#   ** (ArgumentError) could not fetch application environment
#      :validate_header_keys_during_test for application :plug
#   ** (File.Error) could not read file ".../config/config.exs"
#
# Config.Reader handles import_config/1, so reading the root file pulls in the env-specific
# one the same way Mix does. :test is hardcoded because these targets exist to run tests.
#
# Failing to read config is not fatal on purpose: a project with no config/ directory is
# perfectly valid, and should not be forced to have one to get a Bazel test target.
# Load (do NOT start) every application on the code path, so each one's `env` from its
# .app file is in the application environment. `mix test` does this; `elixir -r` does not,
# and the difference is not academic -- Plug reads its own default this way:
#
#   ** (ArgumentError) could not fetch application environment
#      :validate_header_keys_during_test for application :plug
#      because the application was not loaded nor configured
#
# Loading is side-effect free: no supervision trees start, so this stays compatible with a
# test tier that deliberately runs without the application running.
for dir <- :code.get_path(),
    app_file <- Path.wildcard(Path.join(List.to_string(dir), "*.app")) do
  app_file
  |> Path.basename(".app")
  |> String.to_atom()
  |> Application.load()
end

config_path = "config/config.exs"

if File.exists?(config_path) do
  # Some config files call into Mix -- web-ng's does Mix.Project.build_path/0 -- which
  # needs the :mix application running or it exits with
  #   ** (exit) exited in: GenServer.call(Mix.ProjectStack, ...) no process
  # Starting :mix gives Mix.Project.config/0 its defaults without a project on the stack,
  # which is enough for the path helpers those config files use.
  {:ok, _} = Application.ensure_all_started(:mix)
  Mix.env(:test)

  # persistent: true, matching what Mix's own `loadconfig` task does.
  #
  # Without it, Application.load/1 on an app whose config was already applied RESETS that
  # app's environment from the `env` key in its .app file, discarding ours. The load loop
  # above covers everything already on the code path, but an application first loaded later
  # -- by Application.ensure_all_started/1 when a suite boots the app -- is loaded after this
  # point and would clobber its own config. Belt and braces rather than a fix for an observed
  # failure; Mix sets it for the same reason.
  config_path
  |> Config.Reader.read!(env: :test, target: :host)
  |> Application.put_all_env(persistent: true)

  # DELIBERATELY NOT APPLIED TO THE RUNNING LOGGER, despite `config :logger, level: :warning`
  # being in every project's config/test.exs.
  #
  # Logger starts with the VM, long before this file is evaluated, and reads its level once at
  # startup. Putting the level into the application environment afterwards does not move the
  # running logger, so these targets run at Logger's :debug default while `mix test` runs at
  # :warning. Verified:
  #
  #   $ elixir -e 'Application.put_all_env([logger: [level: :warning]], persistent: true);
  #                IO.inspect({Application.get_env(:logger, :level), Logger.level()})'
  #   {:warning, :debug}
  #
  # Adding `Logger.configure(level: level)` here looks like the obvious fix and breaks tests.
  # The PRIMARY level gates a message before any handler sees it, including the one
  # ExUnit.CaptureLog installs -- so `capture_log([level: :info], fn -> Logger.info("x") end)`
  # returns "" at a :warning primary level and "...[info] x..." at :debug. Measured, not
  # assumed. serviceradar_core has 61 capture_log call sites; at least
  # test/serviceradar/plugins/anomaly_addon_profile_seeder_test.exs asks for :info explicitly.
  #
  # The reason anyone wants this -- multi-megabyte logs from Ecto's per-query :debug output,
  # which made Bazel drop the stream entirely:
  #   stdout ... exceeds maximum size of --experimental_ui_max_stdouterr_bytes=1048576; skipping
  # -- is handled at the source instead, with `log: false` on the Repo in config/test.exs.
  # That silences the queries and leaves the primary level alone.
  #
  # Applying the level properly means first auditing those 61 call sites.
end
