defmodule Legion.Store.Conversation.State do
  @moduledoc """
  Replayable state for a persisted agent conversation.

  Stores save this payload after turns so a restarted agent can restore its
  conversation messages and conversation-scoped bindings.
  """

  @enforce_keys [:messages, :bindings]
  defstruct [:messages, :bindings]

  @typedoc "Messages and bindings needed to restore a conversation."
  @type t() :: %__MODULE__{
          messages: [map()],
          bindings: keyword()
        }
end
