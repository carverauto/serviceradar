defmodule ServiceRadar.Plugins.StorageTokenTest do
  # Mutates the global :plugin_storage application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Plugins.StorageToken

  setup do
    original = Application.get_env(:serviceradar_core, :plugin_storage)

    on_exit(fn ->
      if original do
        Application.put_env(:serviceradar_core, :plugin_storage, original)
      else
        Application.delete_env(:serviceradar_core, :plugin_storage)
      end
    end)

    :ok
  end

  # Without a public URL the agent config carries no download URL and the agent
  # can never fetch the Wasm. That has to reach an operator at warning level,
  # not only as a debug line nobody collects.
  test "warns with the artifact when no public URL is configured" do
    Application.put_env(:serviceradar_core, :plugin_storage,
      signing_secret: "test-signing-secret"
    )

    log =
      capture_log([level: :warning], fn ->
        assert StorageToken.download_request("pkg-0001", "plugins/pkg-0001.wasm") == nil
      end)

    assert log =~ "Plugin storage public URL not configured"
    assert log =~ "/artifacts/plugins/pkg-0001/blob/download"
  end
end
