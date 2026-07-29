defmodule Legion.EvalGuard do
  @moduledoc """
  Last check before generated code runs.

  A guard sees the code an agent wrote and decides whether the sandbox may
  evaluate it. It runs after the AST checker has accepted the code and before
  the eval process is spawned, so it is the place for policy the sandbox cannot
  express: "never loop over checkout", "do not read another conversation's
  cart", "no bulk export of the orders table".

  Guards are off unless configured:

      config :legion, :config, %{eval_guard: MyApp.CodeReview}

  or per agent:

      def config, do: %{eval_guard: MyApp.CodeReview}

  ## The callback

      defmodule MyApp.CodeReview do
        @behaviour Legion.EvalGuard

        @impl true
        def check(code, _context) do
          if String.contains?(code, "checkout") and String.contains?(code, "Enum.each") do
            {:deny, "looping over checkout is not allowed - check out once"}
          else
            :allow
          end
        end
      end

  `context` carries `:agent`, `:agent_id`, and `:tools` (the modules the code
  may call).

  A `{:deny, reason}` verdict is handed to the agent as an execution error, so
  it can rewrite the code or explain itself to the user - the same path a
  runtime error takes. Make the reason something an LLM can act on.

  ## Guards run on the critical path

  Whatever a guard does, the agent waits for it. A guard that calls out to an
  LLM adds that round trip to every iteration, and a guard that raises fails
  the evaluation. To review code with a model without paying for it in
  latency, judge *asynchronously*: return `:allow`, and have the guard spawn
  the review, recording verdicts for an audit trail. Blocking on the model is
  worth it only for code you would rather not run at all - and only once the
  async verdicts have shown you what it actually flags.
  """

  alias Legion.Telemetry

  @type context :: %{agent: module(), agent_id: term(), tools: [module()]}

  @callback check(code :: String.t(), context :: context()) :: :allow | {:deny, String.t()}

  @doc false
  def check(nil, _code, _context), do: :allow

  def check(guard, code, context) do
    case guard.check(code, context) do
      :allow ->
        :allow

      {:deny, reason} ->
        Telemetry.emit([:legion, :eval_guard, :denied], %{}, %{
          agent: context.agent,
          guard: guard,
          code: code,
          reason: reason
        })

        {:deny, reason}
    end
  end
end
