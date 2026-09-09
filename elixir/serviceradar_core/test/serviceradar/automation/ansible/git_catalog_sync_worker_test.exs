defmodule ServiceRadar.Automation.Ansible.GitCatalogSyncWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.Ansible.GitCatalogSyncWorker, as: Worker
  alias ServiceRadar.Automation.Ansible.PlaybookRepository

  defp drain_upserts(acc) do
    receive do
      {:upsert, _} = msg -> drain_upserts([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "parse_playbook/2" do
    test "extracts metadata from a single-play playbook" do
      yaml = """
      - name: Deploy web tier
        hosts: tag:web
        tags:
          - deploy
          - web
        vars:
          version: "1.2.3"
          replicas: 3
        vars_prompt:
          - name: confirm
            prompt: "Type yes to proceed"
            private: false
        tasks:
          - name: install
            apt:
              name: nginx
      """

      assert {:ok, args} = Worker.parse_playbook(yaml, "deploy")

      assert args.name == "Deploy web tier"
      assert args.hosts_pattern == "tag:web"
      assert args.tags == ["deploy", "web"]
      assert args.declared_vars == %{"version" => "1.2.3", "replicas" => 3}
      assert [%{"name" => "confirm", "prompt" => _}] = args.vars_prompt
      assert args.parse_status == :ok
      assert args.parse_diagnostics == %{}
    end

    test "falls back to filename when name is missing" do
      yaml = """
      - hosts: all
        tasks:
          - name: hello
            debug:
              msg: "hi"
      """

      assert {:ok, args} = Worker.parse_playbook(yaml, "fallback_name")
      assert args.name == "fallback_name"
      assert args.hosts_pattern == "all"
      assert args.tags == []
    end

    test "handles comma-separated tag string" do
      yaml = """
      - name: x
        hosts: all
        tags: "deploy, web , release"
      """

      assert {:ok, args} = Worker.parse_playbook(yaml, "x")
      assert args.tags == ["deploy", "web", "release"]
    end

    test "uses only the first play's metadata when there are multiple" do
      yaml = """
      - name: First
        hosts: a
      - name: Second
        hosts: b
      """

      assert {:ok, args} = Worker.parse_playbook(yaml, "x")
      assert args.name == "First"
      assert args.hosts_pattern == "a"
    end

    test "empty / scalar playbook still yields a row with fallback name" do
      yaml = "---\n"
      assert {:ok, args} = Worker.parse_playbook(yaml, "fallback")
      assert args.name == "fallback"
      assert args.hosts_pattern == nil
      assert args.tags == []
      assert args.declared_vars == %{}
      assert args.vars_prompt == []
    end

    test "malformed YAML returns {:error, {:parse_error, _}}" do
      yaml = "not: valid: yaml: : :"
      assert {:error, {:parse_error, _}} = Worker.parse_playbook(yaml, "bad")
    end

    test "ignores non-map items in vars_prompt (defensive)" do
      yaml = """
      - name: x
        hosts: all
        vars_prompt:
          - name: confirm
            prompt: "ok?"
          - "scalar string that shouldn't be in here"
      """

      assert {:ok, args} = Worker.parse_playbook(yaml, "x")
      assert length(args.vars_prompt) == 1
      assert hd(args.vars_prompt)["name"] == "confirm"
    end
  end

  describe "discover_yaml_files/1" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "git_catalog_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    test "returns relative paths for .yml / .yaml files, recursively", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "playbooks"))
      File.mkdir_p!(Path.join(tmp, "roles/myrole"))
      File.write!(Path.join(tmp, "deploy.yml"), "")
      File.write!(Path.join(tmp, "playbooks/restart.yaml"), "")
      File.write!(Path.join(tmp, "roles/myrole/tasks.yml"), "")
      File.write!(Path.join(tmp, "README.md"), "")

      paths = tmp |> Worker.discover_yaml_files() |> Enum.sort()

      assert paths == [
               "deploy.yml",
               "playbooks/restart.yaml",
               "roles/myrole/tasks.yml"
             ]
    end

    test "skips dotfiles and dot-dirs", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, ".git/objects"))
      File.write!(Path.join(tmp, ".gitignore"), "")
      File.write!(Path.join(tmp, ".git/config"), "")
      File.write!(Path.join(tmp, "real.yml"), "")

      assert Worker.discover_yaml_files(tmp) == ["real.yml"]
    end

    test "missing directory returns []" do
      assert Worker.discover_yaml_files("/nonexistent/path/#{System.unique_integer()}") == []
    end
  end

  describe "sync_repo/2 (with stubbed git + upsert)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "git_sync_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      repo_dir = Path.join(tmp, "repo-uuid-1")
      File.mkdir_p!(Path.join(repo_dir, ".git"))

      File.write!(Path.join(repo_dir, "deploy.yml"), """
      - name: Deploy
        hosts: all
        tags: [deploy]
      """)

      File.write!(Path.join(repo_dir, "broken.yml"), "not: valid: yaml: : :")

      {:ok, base_dir: tmp, repo_dir: repo_dir}
    end

    test "iterates yaml files, upserts good ones and records error for bad ones",
         %{base_dir: base} do
      repo = %PlaybookRepository{
        id: "repo-uuid-1",
        git_url: "https://github.com/example/playbooks.git",
        git_ref: "main",
        sync_interval_seconds: 600
      }

      test_pid = self()

      git_runner = fn _bin, _args, _opts -> {"", 0} end

      upsert_fn = fn args, _opts ->
        send(test_pid, {:upsert, args})
        {:ok, %{id: "pb-" <> args.path}}
      end

      record_sync_fn = fn _repo, _args, _opts -> {:ok, %{}} end

      assert :ok =
               Worker.sync_repo(repo,
                 actor: nil,
                 base_dir: base,
                 git_runner: git_runner,
                 upsert_fn: upsert_fn,
                 record_sync_fn: record_sync_fn
               )

      msgs = drain_upserts([])

      paths =
        msgs |> Enum.map(fn {:upsert, args} -> {args.path, args.parse_status} end) |> Enum.sort()

      assert {"deploy.yml", :ok} in paths
      assert {"broken.yml", :error} in paths
    end

    test "resolves base dir from :ansible_catalog_base_dir app env when :base_dir opt is absent" do
      configured =
        Path.join(System.tmp_dir!(), "catalog_cfg_#{System.unique_integer([:positive])}")

      prev = Application.get_env(:serviceradar_core, :ansible_catalog_base_dir)
      Application.put_env(:serviceradar_core, :ansible_catalog_base_dir, configured)

      on_exit(fn ->
        File.rm_rf(configured)

        case prev do
          nil -> Application.delete_env(:serviceradar_core, :ansible_catalog_base_dir)
          _ -> Application.put_env(:serviceradar_core, :ansible_catalog_base_dir, prev)
        end
      end)

      repo = %PlaybookRepository{
        id: "repo-cfg-1",
        git_url: "https://github.com/example/playbooks.git",
        git_ref: "main",
        sync_interval_seconds: 600
      }

      test_pid = self()

      git_runner = fn _bin, args, _opts ->
        send(test_pid, {:git_args, args})
        {"fatal: stubbed", 128}
      end

      assert {:error, _} =
               Worker.sync_repo(repo,
                 actor: nil,
                 git_runner: git_runner,
                 upsert_fn: fn _, _ -> {:ok, %{}} end,
                 record_sync_fn: fn _r, _a, _o -> {:ok, %{}} end
               )

      assert_received {:git_args, ["clone" | _] = args}
      assert String.starts_with?(List.last(args), Path.join(configured, "repo-cfg-1"))
    end

    @tag :tmp_dir
    test "configured cache reaches git when temporary directory resolution raises", %{
      tmp_dir: tmp
    } do
      configured = Path.join(tmp, "catalog")
      File.mkdir_p!(configured)
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

      try do
        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
        {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])

        {result, _bindings} =
          :peer.call(peer, Code, :eval_string, [
            """
            import ExUnit.Assertions
            alias ServiceRadar.Automation.Ansible.GitCatalogSyncWorker, as: Worker
            alias ServiceRadar.Automation.Ansible.PlaybookRepository

            Code.compiler_options(ignore_module_conflict: true)

            defmodule System do
              def tmp_dir! do
                raise "could not get a writable temporary directory"
              end
            end

            assert_raise RuntimeError, "could not get a writable temporary directory", fn ->
              System.tmp_dir!()
            end

            Application.put_env(:serviceradar_core, :ansible_catalog_base_dir, configured)

            repo = %PlaybookRepository{
              id: "repo-unavailable-temp",
              git_url: "https://github.com/example/playbooks.git",
              git_ref: "main",
              sync_interval_seconds: 600
            }

            assert {:git_called, ["clone" | _] = args} =
                     catch_throw(
                       Worker.sync_repo(repo,
                         actor: nil,
                         git_runner: fn "git", args, _opts -> throw({:git_called, args}) end
                       )
                     )

            assert List.last(args) == Path.join(configured, repo.id)
            :ok
            """,
            [configured: configured]
          ])

        assert result == :ok
      after
        :peer.stop(peer)
      end
    end

    test "falls back to a tmp-based dir when :ansible_catalog_base_dir app env is unset" do
      prev = Application.get_env(:serviceradar_core, :ansible_catalog_base_dir)
      Application.delete_env(:serviceradar_core, :ansible_catalog_base_dir)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:serviceradar_core, :ansible_catalog_base_dir)
          _ -> Application.put_env(:serviceradar_core, :ansible_catalog_base_dir, prev)
        end
      end)

      repo = %PlaybookRepository{
        id: "repo-fallback-1",
        git_url: "https://github.com/example/playbooks.git",
        git_ref: "main",
        sync_interval_seconds: 600
      }

      test_pid = self()

      git_runner = fn _bin, args, _opts ->
        send(test_pid, {:git_args, args})
        {"fatal: stubbed", 128}
      end

      assert {:error, _} =
               Worker.sync_repo(repo,
                 actor: nil,
                 git_runner: git_runner,
                 upsert_fn: fn _, _ -> {:ok, %{}} end,
                 record_sync_fn: fn _r, _a, _o -> {:ok, %{}} end
               )

      assert_received {:git_args, ["clone" | _] = args}

      expected_prefix =
        Path.join(System.tmp_dir!(), "serviceradar_ansible_catalog/repo-fallback-1")

      assert String.starts_with?(List.last(args), expected_prefix)
    end

    test "cached repositories fetch the configured remote and tag before ingesting", %{
      base_dir: base,
      repo_dir: repo_dir
    } do
      repo = %PlaybookRepository{
        id: "repo-uuid-1",
        git_url: "https://git.example.com/new-catalog.git",
        git_ref: "release-example",
        sync_interval_seconds: 600
      }

      test_pid = self()

      assert :ok =
               Worker.sync_repo(repo,
                 actor: nil,
                 base_dir: base,
                 git_runner: fn "git", args, opts ->
                   send(test_pid, {:git, args, opts[:cd]})
                   {"", 0}
                 end,
                 upsert_fn: fn _, _ -> {:ok, %{}} end,
                 record_sync_fn: fn _, _, _ -> {:ok, %{}} end
               )

      assert_received {:git,
                       ["remote", "set-url", "origin", "https://git.example.com/new-catalog.git"],
                       ^repo_dir}

      assert_received {:git, ["fetch", "--depth", "50", "--prune", "origin", "release-example"],
                       ^repo_dir}

      assert_received {:git, ["reset", "--hard", "FETCH_HEAD"], ^repo_dir}
      refute_received {:git, ["reset", "--hard", "origin/release-example"], _}
    end

    test "a failed remote change never fetches or ingests the previous catalog", %{base_dir: base} do
      repo = %PlaybookRepository{
        id: "repo-uuid-1",
        git_url: "https://git.example.com/new-catalog.git",
        git_ref: "main"
      }

      test_pid = self()

      assert {:error, {:git_failed, 128, _}} =
               Worker.sync_repo(repo,
                 actor: nil,
                 base_dir: base,
                 git_runner: fn "git", args, _ ->
                   send(test_pid, {:git, args})
                   {"synthetic remote update failure", 128}
                 end,
                 upsert_fn: fn _, _ -> send(test_pid, :unexpected_upsert) end,
                 record_sync_fn: fn _, _, _ -> {:ok, %{}} end
               )

      assert_received {:git, ["remote", "set-url", "origin", _]}
      refute_received {:git, ["fetch" | _]}
      refute_received :unexpected_upsert
    end

    test "records error sync when git fails", %{base_dir: base} do
      # Repo that doesn't exist on disk -- ensure_clone tries to clone,
      # fake runner fails.
      repo = %PlaybookRepository{
        id: "repo-fail",
        git_url: "https://github.com/example/playbooks.git",
        git_ref: "main",
        sync_interval_seconds: 600
      }

      test_pid = self()

      git_runner = fn _bin, _args, _opts ->
        {"fatal: repository not found", 128}
      end

      assert {:error, _} =
               Worker.sync_repo(repo,
                 actor: nil,
                 base_dir: base,
                 git_runner: git_runner,
                 upsert_fn: fn _, _ ->
                   send(test_pid, :should_not_upsert)
                   {:ok, %{}}
                 end,
                 record_sync_fn: fn _r, _a, _o -> {:ok, %{}} end
               )

      refute_received :should_not_upsert
    end
  end
end
