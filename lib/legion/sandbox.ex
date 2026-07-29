defmodule Legion.Sandbox do
  @moduledoc """
  Sandboxed code evaluation with AST-level safety checks.

  Evaluates Elixir code strings in a spawned process with:

  - **AST validation** — before evaluation, the code is parsed and walked to reject
    dangerous forms (`defmodule`, `import`, `spawn`, `send`, `receive`, etc.)
    and calls to modules not in the allow-list.
  - **Module allow-list** — only built-in safe modules (Kernel, Enum, Map, String, …)
    and explicitly passed modules may be called. If only some functions from a module
    should be exposed, wrap them in a dedicated facade module.
  - **Timeout** — evaluation runs in a monitored process that is killed if it exceeds
    the deadline.

  ## Examples

      iex> {:ok, {4, _}} = Legion.Sandbox.execute("2 + 2", 5_000)

      iex> {:ok, {6, _}} = Legion.Sandbox.execute("Enum.sum([1, 2, 3])", 5_000)

      iex> {:error, msg} = Legion.Sandbox.execute("System.halt()", 5_000)
      iex> msg =~ "Module System is not allowed"
      true

      iex> {:error, msg} = Legion.Sandbox.execute("import Enum", 5_000)
      iex> msg =~ "import is not allowed"
      true
  """

  alias Legion.Sandbox.ASTChecker

  @doc """
  Evaluates `code_string` in a sandboxed process.

  `timeout_ms` controls the maximum execution time (`:infinity` to disable).
  `allowed_modules` are aliased and made available to the evaluated code
  (on top of the built-in safe modules).

  `limits` bound the resources of the evaluating process (each `:infinity` to
  disable, the default):

    - `:max_heap` — heap budget in bytes; the VM kills the eval on excess
    - `:max_reductions` — CPU budget in reductions, enforced by polling

  Returns `{:ok, {result, new_bindings}}` on success, or `{:error, reason}` on
  validation failure, runtime exception, crash, timeout, or exceeded limit.
  The returned `new_bindings` can be passed to subsequent calls to preserve
  variable scope.
  """
  def execute(code_string, timeout_ms, allowed_modules \\ [], bindings \\ [], limits \\ [])
      when is_binary(code_string) and is_list(allowed_modules) and is_list(limits) and
             (is_integer(timeout_ms) or timeout_ms == :infinity) do
    with :ok <- ASTChecker.check(code_string, allowed_modules) do
      code_string
      |> append_aliases(allowed_modules)
      |> eval(timeout_ms, bindings, limits)
    end
  end

  defp append_aliases(code_string, allowed_modules) do
    aliases =
      for module <- allowed_modules, into: "" do
        "alias #{module}\n"
      end

    aliases <> code_string
  end

  # sobelow_skip ["RCE.CodeModule"]
  defp eval(code_string, timeout_ms, bindings, limits) do
    parent = self()
    max_heap_bytes = Keyword.get(limits, :max_heap, :infinity)
    max_reductions = Keyword.get(limits, :max_reductions, :infinity)

    {pid, ref} =
      spawn_monitor(fn ->
        # Generated code must not starve the node (low priority) or OOM it
        # (max_heap_size makes the VM kill this process at the budget).
        # Both flags also cover tool code called inline from the eval.
        Process.flag(:priority, :low)

        if is_integer(max_heap_bytes) do
          heap_words = div(max_heap_bytes, :erlang.system_info(:wordsize))
          Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: false})
        end

        {result, diagnostics} =
          Code.with_diagnostics(fn ->
            try do
              {value, new_bindings} = Code.eval_string(code_string, bindings)
              {:ok, {value, new_bindings}}
            rescue
              e -> {:error, e}
            catch
              :throw, value -> {:error, {:throw, value}}
              :exit, reason -> {:error, {:exit, reason}}
            end
          end)

        send(parent, {:result, self(), attach_diagnostics(result, diagnostics)})
      end)

    deadline =
      if timeout_ms == :infinity,
        do: :infinity,
        else: System.monotonic_time(:millisecond) + timeout_ms

    await_result(pid, ref, deadline, max_reductions, max_heap_bytes)
  end

  # How often the parent samples the eval's reduction counter. Only relevant
  # when a :max_reductions limit is set - the budget can be overshot by up to
  # one interval's worth of work.
  @reduction_poll_interval_ms 50

  defp await_result(pid, ref, deadline, max_reductions, max_heap_bytes) do
    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      # A :killed exit with a heap budget set is the VM enforcing it - nothing
      # else brutally kills the eval while we still hold its monitor.
      {:DOWN, ^ref, :process, _pid, :killed} when is_integer(max_heap_bytes) ->
        {:error, "evaluation exceeded the memory limit and was killed"}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:process_crashed, reason}}
    after
      wait_ms(deadline, max_reductions) ->
        reductions = reductions_over_budget(pid, max_reductions)

        cond do
          deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
            kill(pid, ref)
            {:error, :timeout}

          reductions != nil ->
            kill(pid, ref)

            {:error,
             "evaluation exceeded the reduction (CPU) limit after ~#{reductions} reductions and was killed"}

          true ->
            await_result(pid, ref, deadline, max_reductions, max_heap_bytes)
        end
    end
  end

  defp wait_ms(:infinity, :infinity), do: :infinity
  defp wait_ms(deadline, :infinity), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp wait_ms(:infinity, _max_reductions), do: @reduction_poll_interval_ms

  defp wait_ms(deadline, _max_reductions) do
    deadline
    |> Kernel.-(System.monotonic_time(:millisecond))
    |> max(0)
    |> min(@reduction_poll_interval_ms)
  end

  defp reductions_over_budget(_pid, :infinity), do: nil

  defp reductions_over_budget(pid, max_reductions) do
    # nil process_info means the eval already exited - its final message is
    # in our mailbox and the next receive picks it up.
    case Process.info(pid, :reductions) do
      {:reductions, reductions} when reductions > max_reductions -> reductions
      _ -> nil
    end
  end

  defp kill(pid, ref) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)

    # The eval may have finished between the budget check and the kill -
    # drop its stray result so it cannot leak into the caller's mailbox.
    receive do
      {:result, ^pid, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp attach_diagnostics({:error, %CompileError{}}, [_ | _] = diagnostics) do
    {:error, format_diagnostics(diagnostics)}
  end

  defp attach_diagnostics(result, _diagnostics), do: result

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "\n", fn diag ->
      "#{format_position(diag.position)}: #{diag.message}"
    end)
  end

  defp format_position({line, column}), do: "#{line}:#{column}"
  defp format_position(line) when is_integer(line), do: "#{line}"
  defp format_position(_), do: "?"
end
