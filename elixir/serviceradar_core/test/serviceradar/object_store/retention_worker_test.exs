defmodule ServiceRadar.ObjectStore.RetentionWorkerTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.ObjectStore.RetentionWorker

  defmodule ReleaseRetentionProbe do
    @moduledoc false
    def run(opts) do
      send(self(), {:release_retention_run, opts})
      {:ok, %{deleted: 0}}
    end
  end

  defmodule NativeAddonRetentionProbe do
    @moduledoc false
    def run(opts) do
      send(self(), {:native_addon_retention_run, opts})
      {:ok, %{deleted: 0}}
    end
  end

  defmodule FailingReleaseRetentionProbe do
    @moduledoc false
    def run(opts) do
      send(self(), {:release_retention_run, opts})
      {:error, :release_retention_failed}
    end
  end

  setup do
    original = Application.get_env(:serviceradar_core, :object_store_retention)

    Application.put_env(:serviceradar_core, :object_store_retention,
      enabled?: true,
      dry_run?: true,
      agent_release_keep_latest: 1,
      native_addon_orphan_grace_seconds: 604_800,
      datasvc_timeout_ms: 30_000,
      release_artifact_retention_module: ReleaseRetentionProbe,
      native_addon_artifact_retention_module: NativeAddonRetentionProbe
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_core, :object_store_retention)
      else
        Application.put_env(:serviceradar_core, :object_store_retention, original)
      end
    end)
  end

  test "perform/1 runs release and native add-on retention with configured arguments" do
    job = %Oban.Job{
      args: %{
        "enabled" => true,
        "dry_run" => false,
        "agent_release_keep_latest" => "2",
        "native_addon_orphan_grace_seconds" => "42",
        "datasvc_timeout_ms" => "1234"
      }
    }

    assert :ok = RetentionWorker.perform(job)

    assert_receive {:release_retention_run, [dry_run?: false, keep_latest: 2, timeout: 1234]}

    assert_receive {:native_addon_retention_run,
                    [
                      dry_run?: false,
                      native_addon_orphan_grace_seconds: 42,
                      timeout: 1234
                    ]}
  end

  test "perform/1 skips retention when disabled" do
    job = %Oban.Job{args: %{"enabled" => false}}

    assert :ok = RetentionWorker.perform(job)
    refute_receive {:release_retention_run, _opts}
    refute_receive {:native_addon_retention_run, _opts}
  end

  test "perform/1 uses configured defaults for scheduled retention jobs" do
    config = Application.fetch_env!(:serviceradar_core, :object_store_retention)

    Application.put_env(
      :serviceradar_core,
      :object_store_retention,
      Keyword.merge(config,
        dry_run?: false,
        agent_release_keep_latest: 7,
        native_addon_orphan_grace_seconds: 99,
        datasvc_timeout_ms: 4321
      )
    )

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{"enabled" => true}})

    assert_receive {:release_retention_run, [dry_run?: false, keep_latest: 7, timeout: 4321]}

    assert_receive {:native_addon_retention_run,
                    [
                      dry_run?: false,
                      native_addon_orphan_grace_seconds: 99,
                      timeout: 4321
                    ]}
  end

  test "perform/1 stops before native add-on retention when release retention fails" do
    config = Application.fetch_env!(:serviceradar_core, :object_store_retention)

    Application.put_env(
      :serviceradar_core,
      :object_store_retention,
      Keyword.put(config, :release_artifact_retention_module, FailingReleaseRetentionProbe)
    )

    job = %Oban.Job{args: %{"enabled" => true}}

    assert {:error, :release_retention_failed} = RetentionWorker.perform(job)
    assert_receive {:release_retention_run, _opts}
    refute_receive {:native_addon_retention_run, _opts}
  end
end
