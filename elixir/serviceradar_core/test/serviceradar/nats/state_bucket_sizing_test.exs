defmodule ServiceRadar.NATS.StateBucketSizingTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.NATS.StateBucketSizing

  @gib 1_073_741_824
  @not_found {:error, %{"code" => 404, "err_code" => 10_059, "description" => "stream not found"}}

  describe "plan/3" do
    test "an absent bucket is created with the cap" do
      assert StateBucketSizing.plan(:absent, 0, 2 * @gib) == :create
    end

    test "a bucket whose data fits is shrunk to the cap" do
      assert StateBucketSizing.plan(10 * @gib, div(@gib, 2), 4 * @gib) == {:update, 4 * @gib}
    end

    test "a bucket whose data fits is grown to the cap" do
      assert StateBucketSizing.plan(@gib, div(@gib, 2), 2 * @gib) == {:update, 2 * @gib}
    end

    test "an unlimited bucket whose data fits gets the cap" do
      for unlimited <- [-1, 0, nil] do
        assert StateBucketSizing.plan(unlimited, div(@gib, 10), @gib) == {:update, @gib}
      end
    end

    test "stored bytes equal to the cap hold max_bytes rather than capping at the stored size" do
      assert StateBucketSizing.plan(10 * @gib, 4 * @gib, 4 * @gib) ==
               {:hold, :stored_exceeds_cap}
    end

    test "stored bytes above the cap hold max_bytes" do
      assert StateBucketSizing.plan(10 * @gib, 6 * @gib, 4 * @gib) ==
               {:hold, :stored_exceeds_cap}
    end

    test "an unlimited bucket holding more than the cap stays unlimited" do
      for unlimited <- [-1, 0, nil] do
        assert StateBucketSizing.plan(unlimited, 3 * @gib, @gib) ==
                 {:hold, :unlimited_stored_exceeds_cap}
      end
    end

    test "a bucket already at the cap is left alone even when full" do
      assert StateBucketSizing.plan(4 * @gib, 4 * @gib, 4 * @gib) == :noop
      assert StateBucketSizing.plan(4 * @gib, 0, 4 * @gib) == :noop
    end

    test "a non-positive cap is rejected" do
      for configured <- [0, -1, nil] do
        assert_raise FunctionClauseError, fn -> StateBucketSizing.plan(-1, 0, configured) end
      end
    end
  end

  describe "ensure/4" do
    setup do
      {:ok, stream: "OBJ_sizing_test_#{System.unique_integer([:positive])}"}
    end

    test "creates an absent bucket with the configured max_bytes", %{stream: stream} do
      request = fake_jetstream(@not_found)
      create_config = %{name: stream, discard: :new, max_bytes: -1, num_replicas: 3}

      assert {:ok, :create} = StateBucketSizing.ensure(request, stream, create_config, 2 * @gib)

      info_subject = "$JS.API.STREAM.INFO.#{stream}"
      create_subject = "$JS.API.STREAM.CREATE.#{stream}"
      assert_received {:js, ^info_subject, ""}
      assert_received {:js, ^create_subject, payload}
      created = Jason.decode!(payload)
      assert created["max_bytes"] == 2 * @gib
      assert created["discard"] == "new"
      assert created["num_replicas"] == 3
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end

    test "caps an unlimited bucket whose data fits, changing nothing else", %{stream: stream} do
      config = stream_config(stream, -1)
      request = fake_jetstream(info(config, div(@gib, 10)))

      assert {:ok, {:update, @gib}} =
               StateBucketSizing.ensure(request, stream, %{name: stream}, @gib)

      update_subject = "$JS.API.STREAM.UPDATE.#{stream}"
      assert_received {:js, ^update_subject, payload}
      assert Jason.decode!(payload) == Map.put(config, "max_bytes", @gib)
      refute_received {:js, "$JS.API.STREAM.CREATE." <> _, _}
    end

    test "leaves a bucket holding more than the cap unchanged and logs the values",
         %{stream: stream} do
      request = fake_jetstream(info(stream_config(stream, 10 * @gib), 6 * @gib))

      log =
        capture_log(fn ->
          assert {:ok, {:hold, :stored_exceeds_cap}} =
                   StateBucketSizing.ensure(request, stream, %{name: stream}, 4 * @gib)
        end)

      assert log =~ stream
      assert log =~ "configured=#{4 * @gib}"
      assert log =~ "stored=#{6 * @gib}"
      assert log =~ "current=#{10 * @gib}"
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
      refute_received {:js, "$JS.API.STREAM.CREATE." <> _, _}
    end

    test "leaves an unlimited bucket holding more than the cap unlimited and logs it",
         %{stream: stream} do
      request = fake_jetstream(info(stream_config(stream, -1), 3 * @gib))

      log =
        capture_log(fn ->
          assert {:ok, {:hold, :unlimited_stored_exceeds_cap}} =
                   StateBucketSizing.ensure(request, stream, %{name: stream}, @gib)
        end)

      assert log =~ "configured=#{@gib}"
      assert log =~ "stored=#{3 * @gib}"
      assert log =~ "current=unlimited"
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end

    test "issues no update for a bucket already at the cap", %{stream: stream} do
      request = fake_jetstream(info(stream_config(stream, @gib), div(@gib, 2)))

      assert {:ok, :noop} = StateBucketSizing.ensure(request, stream, %{name: stream}, @gib)
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
    end

    test "reconciles once, then only recreates a bucket that disappeared", %{stream: stream} do
      fits = fake_jetstream(info(stream_config(stream, -1), 0))

      assert {:ok, {:update, @gib}} =
               StateBucketSizing.ensure(fits, stream, %{name: stream}, @gib)

      assert_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}

      assert {:ok, :exists} = StateBucketSizing.ensure(fits, stream, %{name: stream}, @gib)
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}

      absent = fake_jetstream(@not_found)
      assert {:ok, :create} = StateBucketSizing.ensure(absent, stream, %{name: stream}, @gib)
      assert_received {:js, "$JS.API.STREAM.CREATE." <> _, payload}
      assert Jason.decode!(payload)["max_bytes"] == @gib
    end

    test "returns JetStream errors without recording the bucket as reconciled",
         %{stream: stream} do
      failing = fake_jetstream({:error, %{"code" => 503, "description" => "unavailable"}})

      assert {:error, %{"code" => 503}} =
               StateBucketSizing.ensure(failing, stream, %{name: stream}, @gib)

      fits = fake_jetstream(info(stream_config(stream, -1), 0))

      assert {:ok, {:update, @gib}} =
               StateBucketSizing.ensure(fits, stream, %{name: stream}, @gib)
    end

    test "treats a rejected update as an existing bucket and retries it next call",
         %{stream: stream} do
      rejected =
        fake_jetstream(info(stream_config(stream, -1), 0),
          update:
            {:error,
             %{"code" => 500, "err_code" => 10_047, "description" => "insufficient resources"}}
        )

      log =
        capture_log(fn ->
          assert {:ok, :exists} =
                   StateBucketSizing.ensure(rejected, stream, %{name: stream}, @gib)
        end)

      assert log =~ stream
      assert log =~ "configured=#{@gib}"
      assert log =~ "stored=0"
      assert log =~ "current=unlimited"
      assert log =~ "insufficient resources"
      refute_received {:js, "$JS.API.STREAM.CREATE." <> _, _}

      accepted = fake_jetstream(info(stream_config(stream, -1), 0))

      assert {:ok, {:update, @gib}} =
               StateBucketSizing.ensure(accepted, stream, %{name: stream}, @gib)
    end

    test "treats a stream info reply without stored bytes as an existing bucket",
         %{stream: stream} do
      request = fake_jetstream({:ok, %{"config" => stream_config(stream, -1)}})

      log =
        capture_log(fn ->
          assert {:ok, :exists} = StateBucketSizing.ensure(request, stream, %{name: stream}, @gib)
        end)

      assert log =~ stream
      refute_received {:js, "$JS.API.STREAM.UPDATE." <> _, _}
      refute_received {:js, "$JS.API.STREAM.CREATE." <> _, _}
    end

    test "returns a failure to create an absent bucket", %{stream: stream} do
      request = fn
        "$JS.API.STREAM.INFO." <> _, _ -> @not_found
        "$JS.API.STREAM.CREATE." <> _, _ -> {:error, %{"code" => 500, "description" => "boom"}}
      end

      assert {:error, %{"code" => 500}} =
               StateBucketSizing.ensure(request, stream, %{name: stream}, @gib)
    end
  end

  describe "parse_bytes!/3" do
    test "an unset, empty or blank value uses the default" do
      for value <- [nil, "", "   ", "\t\n"] do
        assert StateBucketSizing.parse_bytes!(value, "SIZE_VAR", 2 * @gib) == 2 * @gib
      end
    end

    test "a positive integer is used" do
      assert StateBucketSizing.parse_bytes!("1073741824", "SIZE_VAR", 2 * @gib) == @gib
      assert StateBucketSizing.parse_bytes!(" 4096 ", "SIZE_VAR", 2 * @gib) == 4096
    end

    test "a non-positive or non-integer value fails naming the variable" do
      for value <- ["0", "-1", "1.5", "2GiB", "abc", "-"] do
        error =
          assert_raise ArgumentError, fn ->
            StateBucketSizing.parse_bytes!(value, "SIZE_VAR", 2 * @gib)
          end

        assert error.message =~ "SIZE_VAR"
        assert error.message =~ inspect(value)
      end
    end
  end

  defp fake_jetstream(info_reply, opts \\ []) do
    test = self()
    update_reply = Keyword.get(opts, :update, {:ok, %{"config" => %{}}})

    fn subject, payload ->
      send(test, {:js, subject, payload})

      cond do
        String.starts_with?(subject, "$JS.API.STREAM.INFO.") -> info_reply
        String.starts_with?(subject, "$JS.API.STREAM.UPDATE.") -> update_reply
        true -> {:ok, %{"did_create" => true}}
      end
    end
  end

  defp info(config, stored_bytes) do
    {:ok, %{"config" => config, "state" => %{"bytes" => stored_bytes, "messages" => 3}}}
  end

  defp stream_config(stream, max_bytes) do
    bucket = String.replace_prefix(stream, "OBJ_", "")

    %{
      "name" => stream,
      "subjects" => ["$O.#{bucket}.C.>", "$O.#{bucket}.M.>"],
      "discard" => "new",
      "allow_rollup_hdrs" => true,
      "max_bytes" => max_bytes,
      "num_replicas" => 1,
      "retention" => "limits",
      "storage" => "file"
    }
  end
end
