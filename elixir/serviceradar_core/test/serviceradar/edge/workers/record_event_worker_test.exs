defmodule ServiceRadar.Edge.Workers.RecordEventWorkerTest do
  @moduledoc """
  Cast coverage for `RecordEventWorker`.

  The live failure was `String.to_existing_atom/1` on a nil `event_type`
  (`ArgumentError: 1st argument: not a binary`) after three Oban attempts.
  Enqueue used to wrap the payload as `new(%{args: inner})`, so Oban stored
  `%{"args" => inner}` and perform/1 never saw `event_type`. These tests
  stay off the database and drive `cast_args/1` plus `perform/1` on the
  branches that used to raise.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.Workers.RecordEventWorker

  describe "cast_args/1" do
    test "accepts the string keys enqueue/3 writes" do
      assert {:ok, attrs} =
               RecordEventWorker.cast_args(%{
                 "package_id" => "pkg-1",
                 "event_type" => "created",
                 "event_time" => "2026-08-12T07:00:58.000000Z",
                 "actor" => "admin@example.com",
                 "source_ip" => "192.0.2.10",
                 "details" => %{"reason" => "ok"}
               })

      assert attrs.event_type == :created
      assert attrs.actor == "admin@example.com"
      assert attrs.source_ip == "192.0.2.10"
    end

    test "unwraps the nested args map the old enqueue/3 stored" do
      assert {:ok, attrs} =
               RecordEventWorker.cast_args(%{
                 "args" => %{
                   "package_id" => "pkg-1",
                   "event_type" => "expired",
                   "actor" => "system"
                 }
               })

      assert attrs.event_type == :expired
      assert attrs.package_id == "pkg-1"
      assert attrs.actor == "system"
    end

    test "accepts an atom event_type left in args" do
      assert {:ok, attrs} =
               RecordEventWorker.cast_args(%{
                 "package_id" => "pkg-1",
                 "event_type" => :expired
               })

      assert attrs.event_type == :expired
    end

    test "accepts atom keys" do
      assert {:ok, attrs} =
               RecordEventWorker.cast_args(%{
                 package_id: "pkg-1",
                 event_type: :delivered
               })

      assert attrs.event_type == :delivered
    end

    test "discards instead of raising when event_type is missing" do
      assert {:discard, :invalid_event_type} =
               RecordEventWorker.cast_args(%{"package_id" => "pkg-1"})
    end

    test "discards an unknown event type string" do
      assert {:discard, :invalid_event_type} =
               RecordEventWorker.cast_args(%{
                 "package_id" => "pkg-1",
                 "event_type" => "not-a-lifecycle"
               })
    end

    test "stringifies a struct actor" do
      assert {:ok, attrs} =
               RecordEventWorker.cast_args(%{
                 "event_type" => "created",
                 "actor" => %{email: "ops@example.com"}
               })

      assert attrs.actor == "ops@example.com"
    end
  end

  describe "new/1" do
    test "stores event fields at the top level of args" do
      changeset =
        RecordEventWorker.new(%{
          "package_id" => "pkg-1",
          "event_type" => "created"
        })

      assert changeset.changes.args["event_type"] == "created"
      refute Map.has_key?(changeset.changes.args, "args")
    end

    test "the old wrap puts event_type under a nested args key" do
      changeset = RecordEventWorker.new(%{args: %{"event_type" => "created"}})
      stored = changeset.changes.args
      nested = stored["args"] || stored[:args]

      assert is_map(nested)
      assert nested["event_type"] == "created"
      refute Map.has_key?(stored, "event_type")
    end
  end

  describe "perform/1" do
    test "does not raise when event_type is nil" do
      job = %Oban.Job{args: %{"package_id" => "pkg-1"}}

      assert {:discard, :invalid_event_type} = RecordEventWorker.perform(job)
    end
  end
end
