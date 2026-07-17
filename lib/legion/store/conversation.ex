defmodule Legion.Store.Conversation do
  @moduledoc """
  One persisted conversation record in a `Legion.Store`.

  A conversation combines the opaque store key with the persisted data a store
  may know about that conversation: identity metadata, current run status, and
  replayable state.
  """

  alias Legion.Store.Conversation.{Metadata, State}

  @enforce_keys [:agent_id]
  defstruct [:agent_id, :metadata, :status, :state]

  @typedoc "Whether the persisted conversation is idle or mid-turn."
  @type status :: :idle | :running

  @typedoc "One persisted conversation record."
  @type t :: %__MODULE__{
          agent_id: Legion.Store.agent_id(),
          metadata: Metadata.t() | nil,
          status: status() | nil,
          state: State.t() | nil
        }
end
