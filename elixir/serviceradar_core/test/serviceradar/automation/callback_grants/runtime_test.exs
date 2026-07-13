defmodule ServiceRadar.Automation.CallbackGrants.RuntimeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Automation.CallbackGrants.AwxCleanup
  alias ServiceRadar.Automation.CallbackGrants.Runtime

  @config_key :automation_callback_grants
  @grant_id "018f3f56-1111-7222-8333-123456789abc"

  defmodule FakeConsumer do
    @moduledoc false

    def delete_activated_credential(grant_id, opts) do
      send(opts[:cleanup_context], {:activated_delete, grant_id, opts})
      {:ok, %{state: :active}}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, @config_key)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:serviceradar_core, @config_key),
        else: Application.put_env(:serviceradar_core, @config_key, previous)
    end)

    :ok
  end

  test "configured runtime defaults to production AWX cleanup for early deletion" do
    Application.put_env(:serviceradar_core, @config_key,
      verifier_config: [active_key_id: "test", keys: %{}],
      consumer: FakeConsumer,
      cleanup_context: self()
    )

    assert {:ok, %{state: :active}} = Runtime.delete_activated_credential(@grant_id)
    assert_receive {:activated_delete, @grant_id, opts}
    assert opts[:cleanup] == AwxCleanup
  end
end
