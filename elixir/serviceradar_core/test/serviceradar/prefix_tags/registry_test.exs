defmodule ServiceRadar.PrefixTags.RegistryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.PrefixTags.Registry
  alias ServiceRadar.PrefixTags.Store

  @registry Registry
  @table ServiceRadar.PrefixTags.Store.Sources

  setup do
    Store.clear()
    on_exit(fn -> Store.clear() end)
    :ok
  end

  test "a supervised restart rehydrates source membership from persistent handles" do
    old_pid = ensure_registry_started()
    source = "registry-restart"

    Store.put_rows(source, [
      %{prefix: "198.51.100.0/24", tags: ["registry:restart"], source: source}
    ])

    assert source in Store.sources()
    assert :ets.info(@table, :owner) == old_pid

    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 2_000

    new_pid = await_registry_restart(old_pid)
    _state = :sys.get_state(new_pid)

    assert :ets.info(@table, :owner) == new_pid
    assert source in Store.sources()

    assert [%{tags: ["registry:restart"], source: ^source}] =
             Store.lookup("198.51.100.10")
  end

  test "cold Store access does not create an unmanaged Registry owner" do
    supervision = stop_application_registry()
    on_exit(fn -> restore_application_registry(supervision) end)

    assert Process.whereis(@registry) == nil
    assert :ets.whereis(@table) == :undefined
    assert Store.sources() == []

    source = "cold-start"

    Store.put_rows(source, [
      %{prefix: "203.0.113.0/24", tags: ["registry:cold"], source: source}
    ])

    # The no-start fallback is entirely persistent-term based. In particular,
    # it must not reserve the production name before a supervisor starts it.
    assert Process.whereis(@registry) == nil
    assert :ets.whereis(@table) == :undefined
    assert source in Store.sources()

    assert [%{tags: ["registry:cold"], source: ^source}] =
             Store.lookup("203.0.113.10")

    registry_pid = restore_or_start_registry(supervision)
    _state = :sys.get_state(registry_pid)

    assert Process.whereis(@registry) == registry_pid
    assert :ets.info(@table, :owner) == registry_pid
    assert source in Store.sources()
  end

  test "concurrent clear and install serialize their handle and membership changes" do
    _registry_pid = ensure_registry_started()
    source = "concurrent-transition"
    ip = "192.0.2.10"

    Store.put_rows(source, [
      %{prefix: "192.0.2.0/24", tags: ["version:initial"], source: source}
    ])

    version_before = Store.active_version(source)
    parent = self()

    {installer, clearer} =
      Registry.with_source_lock(source, fn ->
        installer =
          Task.async(fn ->
            send(parent, {:writer_started, :install})

            result =
              Store.put_rows(source, [
                %{prefix: "192.0.2.0/24", tags: ["version:new"], source: source}
              ])

            send(parent, {:writer_done, :install})
            result
          end)

        clearer =
          Task.async(fn ->
            send(parent, {:writer_started, :clear})
            result = Store.clear(source)
            send(parent, {:writer_done, :clear})
            result
          end)

        assert_receive {:writer_started, :install}, 1_000
        assert_receive {:writer_started, :clear}, 1_000
        refute_receive {:writer_done, _operation}, 100

        {installer, clearer}
      end)

    _installed_version = Task.await(installer, 2_000)
    :ok = Task.await(clearer, 2_000)

    assert Store.active_version(source) == version_before + 2

    registered? = source in Store.sources()
    direct_match? = Store.lookup(ip, source) != []
    aggregate_match? = Enum.any?(Store.lookup(ip), &(&1.source == source))

    assert registered? == direct_match?
    assert registered? == aggregate_match?
  end

  defp ensure_registry_started do
    case Process.whereis(@registry) do
      pid when is_pid(pid) -> pid
      nil -> start_supervised!(@registry)
    end
  end

  defp stop_application_registry do
    case Process.whereis(ServiceRadar.Supervisor) do
      supervisor when is_pid(supervisor) ->
        case registry_child(supervisor) do
          {@registry, pid, _type, _modules} when is_pid(pid) ->
            :ok = Supervisor.terminate_child(supervisor, @registry)
            await_registry_down()
            {:application, supervisor}

          _other ->
            :none
        end

      nil ->
        :none
    end
  end

  defp restore_or_start_registry({:application, supervisor} = supervision) do
    restore_application_registry(supervision)

    case registry_child(supervisor) do
      {@registry, pid, _type, _modules} when is_pid(pid) -> pid
    end
  end

  defp restore_or_start_registry(:none), do: start_supervised!(@registry)

  defp restore_application_registry({:application, supervisor}) do
    if Process.alive?(supervisor) do
      case registry_child(supervisor) do
        {@registry, :undefined, _type, _modules} ->
          case Supervisor.restart_child(supervisor, @registry) do
            {:ok, _pid} -> :ok
            {:ok, _pid, _info} -> :ok
          end

        {@registry, pid, _type, _modules} when is_pid(pid) ->
          :ok

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  defp restore_application_registry(:none), do: :ok

  defp registry_child(supervisor) do
    Enum.find(Supervisor.which_children(supervisor), fn
      {@registry, _pid, _type, _modules} -> true
      _other -> false
    end)
  end

  defp await_registry_restart(old_pid, attempts \\ 200)

  defp await_registry_restart(_old_pid, 0), do: flunk("Registry did not restart")

  defp await_registry_restart(old_pid, attempts) do
    case Process.whereis(@registry) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        Process.sleep(10)
        await_registry_restart(old_pid, attempts - 1)
    end
  end

  defp await_registry_down(attempts \\ 200)

  defp await_registry_down(0), do: flunk("Registry did not stop")

  defp await_registry_down(attempts) do
    if Process.whereis(@registry) == nil and :ets.whereis(@table) == :undefined do
      :ok
    else
      Process.sleep(10)
      await_registry_down(attempts - 1)
    end
  end
end
