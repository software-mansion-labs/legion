defmodule Legion.Store.ConversationMetadata do
  @moduledoc """
  Identity metadata for a persisted agent conversation.

  Stores can save this payload to record which agent module owns a
  conversation, which parent conversation spawned it, and when it started.
  """

  @enforce_keys [:agent_module, :parent_agent_id, :started_at]
  defstruct [:agent_module, :parent_agent_id, :started_at]

  @typedoc "Metadata describing a persisted conversation's agent identity."
  @type t() :: %__MODULE__{
          agent_module: module(),
          parent_agent_id: Legion.Store.agent_id() | nil,
          started_at: integer()
        }
end
