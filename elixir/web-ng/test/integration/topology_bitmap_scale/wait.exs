defmodule ServiceRadarWebNG.Topology.Scale.Wait do
  @moduledoc false

  # Viewer reports carry no session, cookie or CSRF value; these fields are
  # per-sample detail that would only bloat a failure record.
  @detail [:latency_ms, :last_revision, :last_frame_at]

  @doc """
  Polls `read` until `predicate` holds or `deadline` passes. On timeout, or when
  `read` itself exits, raises or throws, the optional `diagnose` record is emitted
  first; the original failure is then preserved exactly.
  """
  def until(read, predicate, deadline, label, diagnose \\ nil) do
    result =
      try do
        read.()
      catch
        kind, reason ->
          stack = __STACKTRACE__
          report(diagnose, label)
          :erlang.raise(kind, reason, stack)
      end

    cond do
      predicate.(result) ->
        result

      now() >= deadline ->
        report(diagnose, label)
        raise ExUnit.AssertionError, message: "#{label} did not complete: #{inspect(result, limit: 20)}"

      true ->
        Process.sleep(500)
        until(read, predicate, deadline, label, diagnose)
    end
  end

  @doc """
  Every viewer's counters and each replica's meters, collected concurrently under
  one total `budget_ms`. Down, failed and unanswered sources are marked as such.
  """
  def diagnostics(viewers, replicas, budget_ms) do
    deadline = now() + budget_ms

    tasks =
      Enum.map(replicas, fn {id, read} ->
        {id,
         Task.async(fn ->
           try do
             {:ok, read.()}
           catch
             kind, _reason -> {:failed, kind}
           end
         end)}
      end)

    requests = Enum.map(viewers, &{&1, :gen_server.send_request(&1.pid, :report)})

    %{
      viewers:
        Enum.map(requests, fn {viewer, request} ->
          row =
            case :gen_server.receive_response(request, remaining(deadline)) do
              {:reply, report} -> Map.drop(report, @detail)
              {:error, _down} -> %{down: true}
              :timeout -> %{timed_out: true}
            end

          Map.merge(row, %{viewer: viewer.id, slow: viewer.opts[:slow]})
        end),
      replicas:
        Enum.map(tasks, fn {id, task} ->
          case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
            {:ok, {:ok, report}} -> Map.put(report, :replica, id)
            {:ok, {:failed, kind}} -> %{replica: id, unavailable: kind}
            _ -> %{replica: id, timed_out: true}
          end
        end)
    }
  end

  @doc """
  Fails at once when a monitored viewer has exited, instead of when the driver
  next calls it. The record carries the viewer's own bounded report for a
  progress stop and only the exit kind otherwise, then all-viewer diagnostics.
  """
  def viewers_alive!(viewers, diagnose) do
    monitors = Map.new(viewers, &{&1.monitor, &1})

    receive do
      {:DOWN, ref, :process, _pid, reason} when is_map_key(monitors, ref) ->
        viewer = Map.fetch!(monitors, ref)
        failure = failure(reason)
        emit("viewer_failed", %{viewer: viewer.id, slow: viewer.opts[:slow], failure: failure})
        report(diagnose, "viewer #{viewer.id} running")
        raise ExUnit.AssertionError, message: "viewer #{viewer.id} exited: #{inspect(failure, limit: 20)}"
    after
      0 -> :ok
    end
  end

  # Other exit reasons can hold transport messages or frame bytes; keep the kind.
  defp failure({:no_progress, report}) when is_map(report), do: Map.put(report, :kind, :no_progress)
  defp failure({%{__exception__: true} = exception, _stack}), do: %{kind: inspect(exception.__struct__)}
  defp failure({kind, _detail}) when is_atom(kind), do: %{kind: kind}
  defp failure(kind) when is_atom(kind), do: %{kind: kind}
  defp failure(_reason), do: %{kind: :other}

  def emit(phase, values), do: IO.puts("TOPOLOGY_BITMAP_SCALE " <> Jason.encode!(Map.put(values, :phase, phase)))

  defp report(nil, _label), do: :ok

  defp report(diagnose, label) do
    emit("wait_failed", Map.put(diagnose.(), :wait, label))
  catch
    kind, reason -> emit("wait_failed", %{wait: label, diagnostics_failed: inspect({kind, reason}, limit: 5)})
  end

  defp remaining(deadline), do: max(deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
