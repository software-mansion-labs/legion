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

  # Generated code runs with a memory budget whether or not the caller asked
  # for one - unbounded is never the right default for code an LLM wrote.
  @default_max_heap 256_000_000

  @doc false
  def default_max_heap, do: @default_max_heap

  @doc """
  Evaluates `code_string` in a sandboxed process.

  `timeout_ms` controls the maximum execution time (`:infinity` to disable).
  `allowed_modules` are aliased and made available to the evaluated code
  (on top of the built-in safe modules).

  `limits` bound what the evaluating process may take from the node:

    - `:max_heap` — memory budget in bytes, applied twice: the VM kills the eval
      when its heap and stack exceed it, and the parent kills it when the
      binaries it references do (those live off-heap, so the VM flag misses them).
      Set `:infinity` to disable (default: `#{@default_max_heap}`)
    - `:max_reductions` — CPU budget in reductions, enforced by polling. Set
      `:infinity` to disable (default: `:infinity`)
    - `:priority` — scheduler priority for the eval, any value `Process.flag/2`
      accepts (default: `:low`, so generated code yields to the rest of the node)

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
    max_heap_bytes = Keyword.get(limits, :max_heap, @default_max_heap)
    max_reductions = Keyword.get(limits, :max_reductions, :infinity)
    priority = Keyword.get(limits, :priority, :low)

    {pid, ref} =
      spawn_monitor(fn ->
        # Generated code must not starve the node (hence the default :low
        # priority) or OOM it (max_heap_size makes the VM kill this process once
        # its heap and stack pass the budget; binaries are the parent's job, see
        # await_result/5). Both flags also cover tool code called inline.
        Process.flag(:priority, priority)

        if is_integer(max_heap_bytes) do
          # A size of 0 means "no limit" and the VM rejects anything under its
          # own minimum heap, so a small budget floors at that minimum - left
          # alone, it would silently disable the flag or fail to set it at all.
          {:min_heap_size, min_words} = :erlang.system_info(:min_heap_size)
          heap_words = max(div(max_heap_bytes, :erlang.system_info(:wordsize)), min_words)
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

  # How often the parent samples the eval's reduction counter and binary
  # footprint. Only relevant when one of those limits is set - either budget
  # can be overshot by up to one interval's worth of work.
  @poll_interval_ms 50

  defp await_result(pid, ref, deadline, max_reductions, max_heap_bytes) do
    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      # A :killed exit with a heap budget set is the VM enforcing it - nothing
      # else brutally kills the eval while we still hold its monitor.
      {:DOWN, ^ref, :process, _pid, :killed} when is_integer(max_heap_bytes) ->
        {:error, memory_limit_error()}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:process_crashed, reason}}
    after
      wait_ms(deadline, polling?(max_reductions, max_heap_bytes)) ->
        reductions = reductions_over_budget(pid, max_reductions)
        binary_bytes = binaries_over_budget(pid, max_heap_bytes)

        cond do
          deadline != :infinity and System.monotonic_time(:millisecond) >= deadline ->
            kill(pid, ref)
            {:error, :timeout}

          reductions != nil ->
            kill(pid, ref)

            {:error,
             "evaluation exceeded the reduction (CPU) limit after ~#{reductions} reductions and was killed"}

          binary_bytes != nil ->
            kill(pid, ref)
            {:error, memory_limit_error()}

          true ->
            await_result(pid, ref, deadline, max_reductions, max_heap_bytes)
        end
    end
  end

  defp memory_limit_error, do: "evaluation exceeded the memory limit and was killed"

  defp polling?(max_reductions, max_heap_bytes),
    do: is_integer(max_reductions) or is_integer(max_heap_bytes)

  defp wait_ms(:infinity, false), do: :infinity
  defp wait_ms(deadline, false), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp wait_ms(:infinity, true), do: @poll_interval_ms

  defp wait_ms(deadline, true) do
    deadline
    |> Kernel.-(System.monotonic_time(:millisecond))
    |> max(0)
    |> min(@poll_interval_ms)
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

  defp binaries_over_budget(_pid, :infinity), do: nil

  defp binaries_over_budget(pid, max_heap_bytes) do
    # :max_heap_size counts the heap and stack only, so binaries over 64 bytes
    # - the cheapest way for generated code to eat the node - slip past it.
    # A process can reference the same binary many times, hence the uniq.
    with {:binary, entries} <- Process.info(pid, :binary) do
      bytes =
        entries
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.sum_by(&elem(&1, 1))

      if bytes > max_heap_bytes, do: bytes
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
