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

  Returns `{:ok, {result, new_bindings}}` on success, or `{:error, reason}` on
  validation failure, runtime exception, crash, or timeout. The returned
  `new_bindings` can be passed to subsequent calls to preserve variable scope.
  """
  def execute(code_string, timeout_ms, allowed_modules \\ [], bindings \\ [])
      when is_binary(code_string) and is_list(allowed_modules) and
             (is_integer(timeout_ms) or timeout_ms == :infinity) do
    with :ok <- ASTChecker.check(code_string, allowed_modules) do
      code_string
      |> append_aliases(allowed_modules)
      |> eval(timeout_ms, bindings)
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
  defp eval(code_string, timeout_ms, bindings) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
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

    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:process_crashed, reason}}
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
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
