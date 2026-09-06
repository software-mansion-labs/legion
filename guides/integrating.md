# Adding Legion to an existing app

This guide drops Legion into an application that already has its contexts,
schemas and authentication - a small shop with `MyShop.Orders` and
`MyShop.Catalog`. Nothing gets rewritten: Legion is one dependency, one
supervisor child and a few plain modules next to the code you have.

## 1. Install

The [Installation](installation.md) guide has the details; the short version:

```elixir
# mix.exs
{:legion, "~> 0.5"}

# lib/my_shop/application.ex
children = [MyShop.Repo, MyShopWeb.Endpoint, Legion]

# config/runtime.exs
config :req_llm, openai_api_key: System.get_env("OPENAI_API_KEY")
```

## 2. Wrap the code you already have as tools

`use Legion.Tool` on a module and the LLM reads its source and calls its
public functions. Two decisions shape every tool:

- **What to expose.** The agent can call any public function, so give it a
  small facade over your context rather than the context itself.
- **Who is asking.** Keep the shopper's identity in
  [Vault](https://github.com/dimamik/vault) and read it inside the tool.
  Generated code never sees it, so it cannot ask for someone else's orders.

```elixir
defmodule MyShop.Tools.OrdersTool do
  use Legion.Tool

  @doc "Orders of the signed-in shopper, newest first"
  def my_orders do
    %{id: shopper_id} = Vault.get(:current_user)

    for order <- MyShop.Orders.list_orders(shopper_id: shopper_id) do
      %{
        id: order.id,
        placed_at: order.placed_at,
        status: order.status,
        items: Enum.map(order.items, & &1.name)
      }
    end
  end

  @doc "Carrier tracking status for one of the shopper's orders"
  def track(order_id) do
    %{id: shopper_id} = Vault.get(:current_user)
    MyShop.Orders.tracking(shopper_id, order_id)
  end
end

defmodule MyShop.Tools.CatalogTool do
  use Legion.Tool

  @doc "Searches products by free text; returns name, price and stock"
  def search(query), do: MyShop.Catalog.search(query)
end
```

Return plain maps with the fields the agent needs, not whole schemas. Tool
results go into the conversation, so this is both a token budget and a
privacy line - a `%User{}` with its hashed password has no business there.

## 3. Describe the agent

```elixir
defmodule MyShop.SupportAgent do
  @moduledoc """
  Helps a signed-in shopper with orders, tracking and product questions.
  Never invents order data - if a tool returns nothing, say so.
  """
  use Legion.Agent

  def tools, do: [MyShop.Tools.OrdersTool, MyShop.Tools.CatalogTool]
end
```

The moduledoc is the agent's job description and becomes its system prompt.
`config/0` overrides the global settings per agent - a cheaper model for a
support bot, fewer iterations for a classifier. See `Legion.Agent`.

## 4. Talk to it from where the shopper is

In a LiveView or controller, after your usual authentication:

```elixir
Vault.init(current_user: %{id: socket.assigns.current_user.id})
{:ok, pid} = Legion.start_link(MyShop.SupportAgent)

{:ok, reply} = Legion.call(pid, "Where is the hoodie I ordered last week?")
{:ok, reply} = Legion.call(pid, "Do you still have it in green?")
```

For the first question the model writes one snippet and runs it in the
sandbox:

```lua
local orders = OrdersTool.my_orders()
for _, order in ipairs(orders) do
  for _, item in ipairs(order.items) do
    if string.find(string.lower(item), "hoodie") then
      return OrdersTool.track(order.id)
    end
  end
end
return "no hoodie among the recent orders"
```

Fetch, filter, follow up - one round trip where a tool-calling agent needs
three. The second question reuses the conversation, so the model already
knows which hoodie.

`Legion.start_link/2` links the agent to the caller: in a LiveView it dies
with the socket, which is what a chat panel wants. To outlive a request,
supervise it instead:

```elixir
DynamicSupervisor.start_child(MyShop.AgentSupervisor, {MyShop.SupportAgent, []})
```

## 5. When the shop grows

- **Deploys mid-chat** - `Legion.Store.Postgres` on your repo, an `agent_id`
  per shopper, and `Legion.resume/2` brings the conversation back.
- **Abuse** - `Legion.RateLimiter.Postgres` caps agents and tokens per
  shopper or per IP.
- **Writes** - a `CartTool.add/2` is one more public function and Vault still
  decides whose cart. Keep irreversible actions (charging a card, cancelling
  an order) out of the agent's reach or behind a confirmation step in your UI.
- **Watching it work** - `Legion.Telemetry.attach_default_logger/0` for logs,
  [legion_web](https://github.com/software-mansion-labs/legion_web) for a live
  dashboard of every conversation and generated snippet.
- **Trust model** - Lua is the default for a reason; [Sandboxes](sandboxes.md)
  explains when the Elixir sandbox is the better fit.
