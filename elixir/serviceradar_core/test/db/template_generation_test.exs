ExUnit.start()
Code.require_file("template_generation.exs", __DIR__)

defmodule ServiceRadar.DB.TemplateGenerationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.DB.TemplateGeneration

  # Invented input; digest vectors were computed independently by manifest.py.
  @digest "4bcdf1b7f5f427e53d47e272b22f8a8a281f41b65816284346a98c22d49999b2"
  @covered "059dfa46f74511be0e7d6095d94c7478d4ff629d61174a4c750ecc117e63757e"
  @input %{
    "path" => "elixir/serviceradar_core/priv/repo/migrations/1_create_example.exs",
    "sha256" => String.duplicate("0", 64)
  }

  defp manifest do
    %{
      "version" => 1,
      "digest" => @digest,
      "database" => "sr_tpl_" <> binary_part(@digest, 0, 48),
      "inputs" => [@input],
      "migration_versions" => [1],
      "covered_migrations" => %{"included_through" => 1, "digest" => @covered}
    }
  end

  test "accepts the producer's binary digest and covered-migrations vector" do
    expected = manifest()
    assert ^expected = TemplateGeneration.validate_manifest!(expected)
  end

  test "rejects a manifest without required covered migrations" do
    expected = Map.delete(manifest(), "covered_migrations")
    assert_raise ArgumentError, fn -> TemplateGeneration.validate_manifest!(expected) end
  end

  test "worker quiescence requires an affirmative acknowledgement" do
    assert :ok = TemplateGeneration.validate_worker_quiescence!([[true]])

    for rows <- [[[false]], [], [[nil]], [["true"]], [[true], [true]]] do
      assert_raise RuntimeError, ~r/shutdown was not acknowledged/, fn ->
        TemplateGeneration.validate_worker_quiescence!(rows)
      end
    end
  end

  test "publication requires an affirmative zero-backend result" do
    assert :ok = TemplateGeneration.validate_no_candidate_backends!([[0]])

    for rows <- [[[1]], [[2]], [], [[nil]], [["0"]], [[0], [0]]] do
      assert_raise RuntimeError, ~r/publication refused/, fn ->
        TemplateGeneration.validate_no_candidate_backends!(rows)
      end
    end
  end

  test "backend draining retries transient sessions within the remaining deadline" do
    assert {:wait, 250} = TemplateGeneration.backend_drain_step!([[2]], 1_000)
    assert {:wait, 40} = TemplateGeneration.backend_drain_step!([[1]], 40)
    assert :drained = TemplateGeneration.backend_drain_step!([[0]], 10)

    for remaining <- [0, -1] do
      assert_raise RuntimeError, ~r/drain timed out/, fn ->
        TemplateGeneration.backend_drain_step!([[1]], remaining)
      end
    end

    for rows <- [[], [[nil]], [["0"]], [[-1]], [[0], [0]]] do
      assert_raise RuntimeError, ~r/could not be verified/, fn ->
        TemplateGeneration.backend_drain_step!(rows, 1_000)
      end
    end
  end

  @tag :manifest_artifact
  test "every environment-name literal in declared migrations has a construction constraint" do
    manifest = "../../build/schema_template/manifest.json" |> File.read!() |> JSON.decode!()

    inputs =
      Enum.filter(
        manifest["inputs"],
        &String.starts_with?(&1["path"], "elixir/serviceradar_core/priv/repo/migrations/")
      )

    refute inputs == []

    constrained =
      MapSet.new([
        "MIX_ENV",
        "SERVICERADAR_MIGRATION_ONLY" | TemplateGeneration.schema_override_names()
      ])

    for %{"path" => path} <- inputs do
      names = path |> then(&Path.join("../..", &1)) |> File.read!() |> environment_literals()

      assert MapSet.subset?(names, constrained),
             "unconstrained migration environment names in #{path}: #{inspect(MapSet.difference(names, constrained))}"
    end
  end

  test "environment inventory reads full AST string literals, not comments or SQL fragments" do
    source = """
    # IGNORED_COMMENT_NAME
    @tables [{"logs", "EXAMPLE_RETENTION_DAYS"}]
    System.get_env("EXAMPLE_SWITCH")
    execute("SELECT EXAMPLE_SQL_COLUMN FROM example")
    """

    assert environment_literals(source) ==
             MapSet.new(["EXAMPLE_RETENTION_DAYS", "EXAMPLE_SWITCH"])
  end

  # Parsing (never evaluating) includes literal names supplied through attributes,
  # table tuples, pipelines and helper arguments. Anchoring to the entire literal
  # excludes comments, prose and SQL; no substring scan of source is involved.
  defp environment_literals(source) do
    {_, names} =
      Macro.prewalk(Code.string_to_quoted!(source), MapSet.new(), fn
        value, names when is_binary(value) ->
          names =
            if Regex.match?(~r/\A[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\z/, value),
              do: MapSet.put(names, value),
              else: names

          {value, names}

        node, names ->
          {node, names}
      end)

    names
  end

  @tag :manifest_artifact
  test "validates the declared generated manifest and policy across languages" do
    manifest = "../../build/schema_template/manifest.json" |> File.read!() |> JSON.decode!()
    policy = "../../build/schema_template/policy.json" |> File.read!() |> JSON.decode!()
    assert ^manifest = TemplateGeneration.validate_manifest!(manifest)
    assert ^policy = TemplateGeneration.validate_policy!(policy)
  end

  test "strictly validates every policy field and bound" do
    policy = %{
      "version" => 1,
      "construction_mode" => "full_replay",
      "max_generations" => 16,
      "max_concurrent_builders" => 1,
      "max_total_bytes" => 21_474_836_480,
      "retention_seconds" => 86_400,
      "lease_seconds" => 7_200,
      "lock_timeout_seconds" => 300
    }

    assert ^policy = TemplateGeneration.validate_policy!(policy)

    for key <- Map.keys(policy) do
      assert_raise ArgumentError, fn ->
        TemplateGeneration.validate_policy!(Map.delete(policy, key))
      end
    end

    for invalid <- [
          Map.put(policy, "extra", true),
          Map.put(policy, "max_concurrent_builders", 17),
          Map.put(policy, "construction_mode", "baseline"),
          Map.put(policy, "lease_seconds", 0),
          Map.put(policy, "max_total_bytes", 2_147_483_647 * 1024 + 1)
        ] do
      assert_raise ArgumentError, fn -> TemplateGeneration.validate_policy!(invalid) end
    end
  end

  test "normalizes a URL-only stopped Repo configuration with URL precedence" do
    url =
      "postgresql://application:synthetic-secret@db.example.com:5433/#{manifest()["database"]}?sslmode=verify-full"

    normalized =
      TemplateGeneration.normalize_repo_config!(url: url, database: "stale", ssl: ssl())

    assert normalized[:database] == manifest()["database"]
    assert normalized[:hostname] == "db.example.com"
    assert normalized[:port] == 5433
    assert normalized[:username] == "application"
    assert normalized[:ssl] == ssl()

    assert_raise ArgumentError, fn ->
      TemplateGeneration.normalize_repo_config!(url: url <> "&ssl=false")
    end
  end

  test "refuses application roles capable of changing shared cluster roles" do
    assert :ok = TemplateGeneration.validate_migration_role!([[false, false, true]])

    for role <- [
          [[true, false, true]],
          [[false, true, true]],
          [[true, true, true]],
          [[false, false, false]],
          []
        ] do
      assert_raise RuntimeError, ~r/without SUPERUSER or CREATEROLE/, fn ->
        TemplateGeneration.validate_migration_role!(role)
      end
    end
  end

  test "rejects unsupported versions and malformed structures" do
    for invalid <- [
          nil,
          [],
          %{},
          Map.put(manifest(), "version", 2),
          Map.put(manifest(), "inputs", nil),
          Map.put(manifest(), "migration_versions", []),
          Map.put(manifest(), "digest", "abc")
        ] do
      assert_raise ArgumentError, fn -> TemplateGeneration.validate_manifest!(invalid) end
    end
  end

  test "rejects unsafe or non-deterministic candidate names" do
    for database <- [
          "postgres",
          "sr_core_template",
          "sr_tpl_'unsafe",
          "sr_tpl_" <> String.duplicate("f", 48)
        ] do
      assert_raise ArgumentError, fn ->
        TemplateGeneration.validate_manifest!(Map.put(manifest(), "database", database))
      end
    end
  end

  test "rejects changed bytes or paths even when the candidate prefix is unchanged" do
    for input <- [
          Map.put(@input, "sha256", String.duplicate("1", 64)),
          Map.put(@input, "path", "another.exs")
        ] do
      assert_raise ArgumentError, ~r/digest mismatch/, fn ->
        TemplateGeneration.validate_manifest!(Map.put(manifest(), "inputs", [input]))
      end
    end
  end

  test "rejects a different full digest with the same 48-character database suffix" do
    changed = binary_part(@digest, 0, 48) <> String.duplicate("0", 16)

    assert_raise ArgumentError, ~r/digest mismatch/, fn ->
      TemplateGeneration.validate_manifest!(Map.put(manifest(), "digest", changed))
    end
  end

  test "rejects duplicate paths, unsafe paths, and non-hex content hashes" do
    for inputs <- [
          [@input, @input],
          [Map.put(@input, "path", "../outside.exs")],
          [Map.put(@input, "path", "/absolute.exs")],
          [Map.put(@input, "path", "a//b.exs")],
          [Map.put(@input, "sha256", String.duplicate("g", 64))]
        ] do
      assert_raise ArgumentError, fn ->
        TemplateGeneration.validate_manifest!(Map.put(manifest(), "inputs", inputs))
      end
    end
  end

  test "requires unique sorted positive bigint migration versions matching input paths" do
    for versions <- [[1, 1], [2, 1], [0], [-1], [1.0], ["1"], [9_223_372_036_854_775_808], [2]] do
      assert_raise ArgumentError, fn ->
        TemplateGeneration.validate_manifest!(Map.put(manifest(), "migration_versions", versions))
      end
    end
  end

  test "verifies the covered migration digest" do
    covered = %{"included_through" => 1, "digest" => String.duplicate("0", 64)}

    assert_raise ArgumentError, ~r/covered migration digest mismatch/, fn ->
      TemplateGeneration.validate_manifest!(Map.put(manifest(), "covered_migrations", covered))
    end
  end

  test "uses signed big-endian first four digest bytes for the lock" do
    for {prefix, expected} <- [
          {"00000000", 0},
          {"7fffffff", 2_147_483_647},
          {"80000000", -2_147_483_648},
          {"ffffffff", -1}
        ] do
      assert TemplateGeneration.lock_key(prefix <> String.duplicate("0", 56)) == expected
    end

    assert_raise ArgumentError, fn -> TemplateGeneration.lock_key("ffffffff") end
  end

  defp ssl do
    [verify: :verify_peer, cacerts: [<<1, 2, 3>>], server_name_indication: ~c"db.example.com"]
  end

  defp config, do: [hostname: "db.example.com", port: 5432, ssl: ssl()]

  test "admin options preserve verified Repo TLS and isolate the lock connection" do
    options =
      TemplateGeneration.admin_options!(
        "postgresql://builder:synthetic%3Asecret@db.example.com/postgres?sslmode=verify-full",
        config()
      )

    assert options[:ssl] == ssl()
    assert options[:database] == "postgres"
    assert options[:password] == "synthetic:secret"
    assert options[:pool_size] == 1
    assert options[:backoff_type] == :stop
    refute options[:show_sensitive_data_on_connection_error]
  end

  test "admin options reject endpoint overrides and TLS downgrades without exposing credentials" do
    base = "postgresql://builder:synthetic-secret@db.example.com/postgres"

    for url <- [
          base <> "?ssl=false",
          base <> "?database=another",
          base <> "?sslmode=disable",
          base <> "?ssl=true&ssl=true",
          String.replace(base, "db.example.com", "other.example.com"),
          String.replace(base, "/postgres", "/another")
        ] do
      error =
        assert_raise ArgumentError, fn -> TemplateGeneration.admin_options!(url, config()) end

      refute Exception.message(error) =~ "synthetic-secret"
    end

    for tls <- [
          false,
          true,
          [],
          Keyword.put(ssl(), :verify, :verify_none),
          Keyword.delete(ssl(), :cacerts),
          Keyword.delete(ssl(), :server_name_indication)
        ] do
      assert_raise ArgumentError, fn ->
        TemplateGeneration.admin_options!(base, Keyword.put(config(), :ssl, tls))
      end
    end
  end

  test "a disconnect kills a busy migration owner even when it traps exits" do
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        watcher = TemplateGeneration.start_disconnect_guard()
        send(parent, {:watcher, self(), watcher})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:watcher, ^owner, watcher}
    send(watcher, {:disconnected, self()})
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000
  end

  test "underlying connection death kills the owner even if its pool could restart" do
    parent = self()

    connection =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {owner, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        watcher = TemplateGeneration.start_disconnect_guard()
        send(watcher, {:connected, connection})
        send(parent, {:watcher, self(), watcher})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:watcher, ^owner, _watcher}
    send(connection, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000
  end

  test "normal guard shutdown permits intentional disconnect after publication" do
    watcher = TemplateGeneration.start_disconnect_guard()
    assert :ok = TemplateGeneration.stop_disconnect_guard(watcher)
    send(watcher, {:disconnected, self()})
    assert :ok = TemplateGeneration.stop_disconnect_guard(watcher)
    refute Process.alive?(watcher)
  end
end

defmodule ServiceRadar.DB.TemplateGenerationEnvironmentTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.DB.TemplateGeneration

  setup do
    keys = ["MIX_ENV", "SERVICERADAR_MIGRATION_ONLY" | TemplateGeneration.schema_override_names()]
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(keys, &System.delete_env/1)
    System.put_env("MIX_ENV", "test")
    :ok
  end

  test "rejects every literal and table-driven override without exposing values" do
    assert :ok = TemplateGeneration.validate_environment!()

    for key <- TemplateGeneration.schema_override_names() do
      System.put_env(key, "synthetic-sensitive-value")
      error = assert_raise ArgumentError, fn -> TemplateGeneration.validate_environment!() end
      refute Exception.message(error) =~ "synthetic-sensitive-value"
      System.delete_env(key)
    end

    assert :ok = TemplateGeneration.validate_environment!()
  end

  test "requires test mode and fixes the migration-only switch" do
    System.put_env("MIX_ENV", "prod")
    assert_raise ArgumentError, fn -> TemplateGeneration.validate_environment!() end
    System.put_env("MIX_ENV", "test")
    System.put_env("SERVICERADAR_MIGRATION_ONLY", "false")
    assert_raise ArgumentError, fn -> TemplateGeneration.validate_environment!() end
    System.put_env("SERVICERADAR_MIGRATION_ONLY", "true")
    assert :ok = TemplateGeneration.validate_environment!()
  end
end
