defmodule ServiceRadar.Edge.DirectLeafScopeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.DirectLeafScope

  test "derives bounded OTEL publish and request scopes" do
    assert {:ok, scope} =
             DirectLeafScope.build(%{
               "nats" => %{
                 "subject" => "events.otlp",
                 "logs_subject" => "logs.otel",
                 "stream" => "events"
               }
             })

    assert scope["publish"] == [
             "events.otlp.traces.>",
             "events.otlp.metrics.>",
             "logs.otel",
             "$JS.API.STREAM.INFO.events",
             "$JS.API.STREAM.CREATE.events",
             "$JS.API.STREAM.UPDATE.events"
           ]

    assert scope["subscribe"] == ["_INBOX.>", "$JS.ACK.events.>"]

    assert DirectLeafScope.subject_within_scope?(
             "events.otlp.metrics.derived",
             "events.otlp.metrics.>"
           )

    refute DirectLeafScope.subject_within_scope?("events.other.secret", "events.otlp.metrics.>")
  end

  test "uses the configured base subject for the derived logs subject" do
    assert {:ok, scope} = DirectLeafScope.build(%{"nats" => %{"subject" => "edge.telemetry"}})
    assert Enum.at(scope["publish"], 2) == "edge.telemetry.logs"
  end

  test "rejects wildcard, reserved, and malformed subjects" do
    for subject <- ["events.>", "$JS.API.>", "events.*", "events..otlp", "events otlp"] do
      assert {:error, :invalid_subject_scope} =
               DirectLeafScope.build(%{"nats" => %{"subject" => subject}})
    end
  end

  test "rejects malformed stream names" do
    assert {:error, :invalid_subject_scope} =
             DirectLeafScope.build(%{"nats" => %{"stream" => "events.>"}})
  end
end
