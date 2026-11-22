defmodule ServiceRadar.Credo.Check.Warning.AtomicDropsChangeHookTest do
  use Credo.Test.Case

  alias ServiceRadar.Credo.Check.Warning.AtomicDropsChangeHook

  # The check lives outside `lib/`, so it is compiled here. Not at file load:
  # `use Credo.Check` reads the Mix project, and the integration selection
  # tooling loads every test file without running Mix or any test.
  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)

    if !Code.ensure_loaded?(AtomicDropsChangeHook) do
      Code.require_file("../../credo/check/warning/atomic_drops_change_hook.ex", __DIR__)
    end

    :ok
  end

  defp issues(source) do
    source
    |> to_source_file("lib/serviceradar/example/changes/example.ex")
    |> run_check(AtomicDropsChangeHook)
  end

  test "flags a bare :ok when change/3 registers an after_action hook" do
    """
    defmodule Example do
      use Ash.Resource.Change

      def change(changeset, _opts, _context) do
        Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)
      end

      def atomic(_changeset, _opts, _context), do: :ok
    end
    """
    |> issues()
    |> assert_issue(&assert(&1.line_no == 8))
  end

  test "flags a hook registered through a helper, in a private function, with a guarded clause" do
    """
    defmodule Example do
      use Ash.Resource.Change

      def change(changeset, _opts, _context), do: publish(changeset)

      def atomic(changeset, _opts, _context) when is_struct(changeset) do
        :ok
      end

      defp publish(changeset) do
        AfterAction.after_action_result(changeset, fn _record -> :ok end)
      end
    end
    """
    |> issues()
    |> assert_issue(&assert(&1.trigger == "atomic"))
  end

  test "flags after_transaction, including when :ok ends a longer body" do
    """
    defmodule Example do
      use Ash.Resource.Change

      def change(changeset, _opts, _context) do
        Ash.Changeset.after_transaction(changeset, fn _changeset, result -> result end)
      end

      def atomic(changeset, _opts, _context) do
        _ = changeset
        :ok
      end
    end
    """
    |> issues()
    |> assert_issue()
  end

  test "accepts atomic/3 that registers the hook" do
    """
    defmodule Example do
      use Ash.Resource.Change

      def change(changeset, _opts, _context) do
        Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)
      end

      def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
    end
    """
    |> issues()
    |> refute_issues()
  end

  test "accepts a bare :ok when the change registers no after hook" do
    """
    defmodule Example do
      use Ash.Resource.Change

      def change(changeset, _opts, _context) do
        Ash.Changeset.change_attribute(changeset, :name, "example")
      end

      def atomic(_changeset, _opts, _context), do: :ok
    end
    """
    |> issues()
    |> refute_issues()
  end

  test "accepts a bare :ok in a module that is not a change" do
    """
    defmodule Example do
      use Ash.Resource.Validation

      def validate(changeset, _opts, _context) do
        _ = Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)
        :ok
      end

      def atomic(_changeset, _opts, _context), do: :ok
    end
    """
    |> issues()
    |> refute_issues()
  end
end
