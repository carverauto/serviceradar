defmodule ServiceRadar.NATS.JetStreamPublishDenialTest do
  @moduledoc """
  A publish the broker denies fails as a denial, on a real nats-server whose user may not
  publish one subject tree.

  The broker never answers a denied publish; it sends the connection an asynchronous
  Permissions Violation. Without classification the publish waits out its PubAck timeout and
  a retrying caller repeats that for every message. A slow broker is not a denial: a publish
  nothing answers, with no violation, stays a timeout.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.NATS.BrokerErrorLogFilter
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.NATS.PublishDenials
  alias ServiceRadar.NATS.PublishDeniedError
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag :capture_log
  @moduletag timeout: 120_000

  @user "synthetic-core"
  @password "synthetic-password"
  @config """
  authorization {
    users = [
      {
        user: "#{@user}"
        password: "#{@password}"
        permissions: {
          publish: { allow: [">"], deny: ["metrics.denied.>"] }
          subscribe: { allow: [">"] }
        }
      }
    ]
  }
  """

  setup do
    :ok = PublishDenials.init()

    :ok =
      BrokerErrorLogFilter.install(
        connection: :serviceradar_nats,
        endpoint: "127.0.0.1",
        credentials: "none"
      )

    on_exit(fn -> :logger.remove_primary_filter(:serviceradar_nats_broker_errors) end)
  end

  test "a denied publish fails as a denial and later ones fail unsent; a silent one times out",
       ctx do
    ExposureBroker.with_broker(
      ctx.tmp_dir,
      fn conn, _port ->
        %{"config" => _} =
          ExposureBroker.request(conn, "$JS.API.STREAM.CREATE.metrics", %{
            name: "metrics",
            subjects: ["metrics.>"],
            storage: "memory"
          })

        assert :ok = JetStreamPublish.publish("metrics.allowed.cpu", "{}")

        assert {:error, %PublishDeniedError{subject: "metrics.denied.cpu"}} =
                 JetStreamPublish.publish("metrics.denied.cpu", "{}", timeout: 1_000)

        # Held: refused without another round trip to the broker.
        {elapsed_us, held} =
          :timer.tc(fn ->
            JetStreamPublish.publish("metrics.denied.cpu", "{}", timeout: 1_000)
          end)

        assert {:error, %PublishDeniedError{subject: "metrics.denied.cpu"}} = held
        assert elapsed_us < 500_000

        # The hold is per subject: an allowed subject still publishes.
        assert :ok = JetStreamPublish.publish("metrics.allowed.memory", "{}")

        # Permitted, but no stream captures it, so nothing answers and no violation arrives.
        assert {:error, :timeout} =
                 JetStreamPublish.publish("unclaimed.subject", "{}", timeout: 300)
      end,
      config: @config,
      connection: %{username: @user, password: @password, auth_required: true}
    )
  end
end
