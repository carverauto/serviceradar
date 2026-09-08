defmodule ServiceRadar.Automation.Ansible.GitCatalogSyncWorkerTest do
  use ExUnit.Case, async: true

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
