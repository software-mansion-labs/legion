defmodule Legion.Store.Payload do
  @moduledoc """
  Data supplied to and returned from a `Legion.Store`.
  """

  @enforce_keys [:agent_id]
  defstruct [
    :agent_id,
    :agent_module,
    :parent_agent_id,
    :status,
    :started_at,
    :conversation_state
  ]

  @type status :: :idle | :running
  @type execution :: %{
          phase: :awaiting_llm | :completing,
          iteration: non_neg_integer(),
          retries: non_neg_integer()
        }
  @type state :: %{
          required(:messages) => [map()],
          required(:bindings) => keyword(),
          optional(:execution) => execution()
        }
  @type t :: %__MODULE__{
          agent_id: Legion.Store.agent_id(),
          agent_module: module() | nil,
          parent_agent_id: Legion.Store.agent_id() | nil,
          status: status() | nil,
          started_at: integer() | nil,
          conversation_state: state() | nil
        }
end
