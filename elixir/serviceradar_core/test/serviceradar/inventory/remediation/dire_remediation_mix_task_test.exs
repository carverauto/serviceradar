defmodule Mix.Tasks.Serviceradar.DireRemediationTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Serviceradar.DireRemediation, as: DireRemediationTask

  @moduletag :requires_app

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(original_shell) end)

    :ok
  end

  test "explicit armis-unmerge dry-run forwards bounded controls and prints its report" do
    test_process = self()

    runner = fn opts ->
      send(test_process, {:engine_opts, opts})

      {:ok,
       %{
         reports: %{
           "armis-unmerge" => %{
             candidate_devices: 2,
             planned_splits: 1,
             split_plan: [%{device_uid: "sr:scoped", new_device_count: 1}],
             execution_split_plan: [
               %{device_uid: "sr:eligible", source_id: "source-reviewed"}
             ],
             skipped_device_sample: [
               %{device_uid: "sr:unsplittable", reason: "no_universal_mac"}
             ]
           }
         },
         manifest_path: nil
       }}
    end

    assert :ok =
             DireRemediationTask.run_with(
               [
                 "--step",
                 "armis-unmerge",
                 "--armis-unmerge-candidate-limit",
                 "200",
                 "--armis-unmerge-plan-sample-limit",
                 "10"
               ],
               runner,
               fn -> :ok end
             )

    assert_receive {:engine_opts, opts}
    assert opts[:mode] == :dry_run
    assert opts[:steps] == ["armis-unmerge"]
    assert opts[:armis_unmerge_candidate_limit] == 200
    assert opts[:armis_unmerge_plan_sample_limit] == 10

    output = shell_output()
    assert output =~ "DRY RUN"
    assert output =~ "== armis-unmerge =="
    assert output =~ "candidate_devices: 2"
    assert output =~ "device_uid=sr:scoped"
    assert output =~ "execution_split_plan:"
    assert output =~ "device_uid=sr:eligible"
    assert output =~ "skipped_device_sample:\n"
    assert output =~ "    - device_uid=sr:unsplittable reason=no_universal_mac"
  end

  test "paired live allowlists are forwarded as an explicit live scope" do
    test_process = self()

    runner = fn opts ->
      send(test_process, {:engine_opts, opts})
      {:ok, %{reports: %{"armis-unmerge" => %{}}, manifest_path: "/tmp/manifest"}}
    end

    assert :ok =
             DireRemediationTask.run_with(
               [
                 "--step",
                 "armis-unmerge",
                 "--execute",
                 "--armis-unmerge-live-device",
                 "sr:one",
                 "--armis-unmerge-live-device",
                 "sr:two",
                 "--armis-unmerge-live-source",
                 "source-reviewed"
               ],
               runner,
               fn -> :ok end
             )

    assert_receive {:engine_opts, opts}
    assert opts[:armis_unmerge_include_live]
    assert opts[:armis_unmerge_live_device_uids] == ["sr:one", "sr:two"]
    assert opts[:armis_unmerge_live_source_ids] == ["source-reviewed"]
    assert shell_output() =~ "== armis-unmerge =="
  end

  test "candidate and plan sample limits are bounded before the app starts" do
    app_starter = fn -> flunk("app must not start for invalid CLI input") end
    runner = fn _opts -> flunk("remediation must not run for invalid CLI input") end

    assert_raise Mix.Error, ~r/--armis-unmerge-candidate-limit must be between 1 and 5000/, fn ->
      DireRemediationTask.run_with(
        ["--step", "armis-unmerge", "--armis-unmerge-candidate-limit", "0"],
        runner,
        app_starter
      )
    end

    assert_raise Mix.Error,
                 ~r/--armis-unmerge-plan-sample-limit must be between 0 and 5000/,
                 fn ->
                   DireRemediationTask.run_with(
                     [
                       "--step",
                       "armis-unmerge",
                       "--armis-unmerge-plan-sample-limit",
                       "5001"
                     ],
                     runner,
                     app_starter
                   )
                 end
  end

  test "live execution scope requires both device and source allowlists" do
    app_starter = fn -> flunk("app must not start for incomplete live scope") end
    runner = fn _opts -> flunk("remediation must not run for incomplete live scope") end

    assert_raise Mix.Error, ~r/requires at least one --armis-unmerge-live-source/, fn ->
      DireRemediationTask.run_with(
        ["--step", "armis-unmerge", "--armis-unmerge-live-device", "sr:one"],
        runner,
        app_starter
      )
    end

    assert_raise Mix.Error, ~r/requires at least one --armis-unmerge-live-device/, fn ->
      DireRemediationTask.run_with(
        ["--step", "armis-unmerge", "--armis-unmerge-live-source", "source-one"],
        runner,
        app_starter
      )
    end
  end

  test "armis-unmerge options require an explicit armis-unmerge step before app start" do
    app_starter = fn -> flunk("app must not start for an invalid Armis selection") end
    runner = fn _opts -> flunk("remediation must not run for an invalid Armis selection") end

    argument_sets = [
      ["--armis-unmerge-candidate-limit", "10"],
      ["--step", "blob-purge", "--armis-unmerge-plan-sample-limit", "5"],
      [
        "--execute",
        "--armis-unmerge-live-device",
        "sr:one",
        "--armis-unmerge-live-source",
        "source-one"
      ]
    ]

    Enum.each(argument_sets, fn args ->
      assert_raise Mix.Error, ~r/require an explicit --step armis-unmerge/, fn ->
        DireRemediationTask.run_with(args, runner, app_starter)
      end
    end)
  end

  test "all cannot be mixed with another step before app start" do
    app_starter = fn -> flunk("app must not start for a mixed all selection") end
    runner = fn _opts -> flunk("remediation must not run for a mixed all selection") end

    assert_raise Mix.Error, ~r/--step all cannot be combined/, fn ->
      DireRemediationTask.run_with(
        ["--step", "all", "--step", "armis-unmerge"],
        runner,
        app_starter
      )
    end
  end

  test "execute gate errors explain how to collect a safe dry-run" do
    runner = fn _opts -> {:error, {:execute_disabled, ["armis-unmerge"]}} end

    assert_raise Mix.Error, ~r/execute mode is disabled pending live-scoping signoff/, fn ->
      DireRemediationTask.run_with(
        ["--step", "armis-unmerge", "--execute"],
        runner,
        fn -> :ok end
      )
    end
  end

  test "nonzero step failures print the report and fail the task" do
    runner = fn _opts ->
      {:error,
       {:step_failures,
        %{
          reports: %{
            "armis-unmerge" => %{applied_splits: 3, split_failures: 1, split_plan: []}
          },
          manifest_path: "/tmp/dire.ndjson",
          failures: %{"armis-unmerge" => %{split_failures: 1}}
        }}}
    end

    assert_raise Mix.Error, ~r/armis-unmerge: split_failures=1/, fn ->
      DireRemediationTask.run_with(
        ["--step", "armis-unmerge", "--execute"],
        runner,
        fn -> :ok end
      )
    end

    output = shell_output()
    assert output =~ "EXECUTED. Rollback manifest: /tmp/dire.ndjson"
    assert output =~ "== armis-unmerge =="
    assert output =~ "split_failures: 1"
  end

  defp shell_output do
    []
    |> receive_shell_messages()
    |> Enum.join("\n")
  end

  defp receive_shell_messages(messages) do
    receive do
      {:mix_shell, level, [message]} when level in [:info, :error] ->
        receive_shell_messages([IO.iodata_to_binary(message) | messages])
    after
      0 -> Enum.reverse(messages)
    end
  end
end
