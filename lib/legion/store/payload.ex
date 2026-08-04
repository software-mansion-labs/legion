defmodule Legion.Store.Payload do
  @moduledoc """
  Data supplied to and returned from a `Legion.Store`.

  Payloads are partial updates: `agent_id` is required, while a `nil` value for
  every other field means the store must preserve its existing value. A
  `conversation_state` holds the persisted messages, bindings, and executor
  checkpoint. Its `:executor_state` value is `nil` for an ordinary snapshot or a
  map when step persistence captures an interrupted turn.

  See `Legion.Store` for the full store contract.
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

  @type executor_state :: %{
          phase: :awaiting_llm | :completing,
          iteration: non_neg_integer(),
          retries: non_neg_integer()
        }

  @type state :: %{
          messages: [map()],
          bindings: keyword(),
          executor_state: executor_state() | nil
        }

  @type t :: %__MODULE__{
          agent_id: Legion.Store.agent_id(),
          agent_module: module() | nil,
          parent_agent_id: Legion.Store.agent_id() | nil,
          status: status() | nil,
          started_at: NaiveDateTime.t() | nil,
          conversation_state: state() | nil
        }
end
