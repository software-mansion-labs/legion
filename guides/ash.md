# Using Legion with Ash

If your app is built on Ash you are most of the way there already. Actions
are the only way in and out of your data, and policies decide who gets to
call them, which is exactly what a Legion tool wants to sit on top of. You should write a `Legion.Tool` that calls
your domain's code interface and passes along the actor it finds in
[Vault](https://github.com/dimamik/vault), and that's the whole
integration.

The examples below assume you have been through the
[integrating](integrating.md) guide and have a domain roughly like this one:

```elixir
defmodule MyApp.Blog do
  use Ash.Domain

  resources do
    resource MyApp.Post do
      define :list_posts, action: :read
      define :create_post, action: :create, args: [:title, :body]
    end
  end
end
```

## The tool

One tool per domain is usually enough. Here is one for the blog:

```elixir
defmodule MyApp.Tools.PostsTool do
  @moduledoc """
  The signed-in user's posts. Only their own posts are visible; a post
  needs a title and a body.
  """
  use Legion.Tool

  alias MyApp.Blog
  alias MyApp.Post

  @public_attributes Post |> Ash.Resource.Info.public_attributes() |> Enum.map(& &1.name)

  @doc "Posts of the signed-in user"
  def mine, do: Blog.list_posts!(actor: actor()) |> public()

  @doc ~S|Searches posts with a filter table, for example `{title = {eq = "Hello"}}`|
  def search(filter) do
    Post
    |> Ash.Query.filter_input(filter)
    |> Ash.Query.limit(50)
    |> Ash.read!(actor: actor())
    |> public()
  end

  @doc ~S|Creates a post from `{title = "...", body = "..."}`|
  def create(attributes) do
    Blog.create_post!(attributes["title"], attributes["body"], actor: actor()) |> public()
  end

  defp actor, do: Vault.get(:current_user)

  defp public(records) when is_list(records), do: Enum.map(records, &public/1)
  defp public(record), do: Map.take(record, @public_attributes)
end
```

Not much to it, but a few of those lines matter more than they seem to.

Every call passes `actor: actor()`. The tool can read Vault because it runs
in the sandbox's eval process, but the code the model wrote is not a
`Legion.Tool` and has no way to reach Vault or to sneak in an actor of its
own. So your policies run for the agent the same way they run for a
controller. If nobody initialized Vault the actor is `nil`, and your
policies already say what a `nil` actor may do (usually nothing), so a
missing Vault fails closed without any extra code.

Anything the model wrote goes through `Ash.Query.filter_input/2`. Lua tables
show up in Elixir as string-keyed maps, and that happens to be the shape
`filter_input`, `sort_input` and `for_create` expect, so there is no
conversion step. Private attributes and fields that aren't filterable get
rejected with an error the model can read, and field policies turn forbidden
references into `nil`. You never need the `Ash.Query.filter` macro on that
path, which is convenient because the model couldn't use it anyway.

Every result goes through `public/1`. More on that in a moment.

Starting the agent looks the same as in any other Legion app:

```elixir
Vault.init(current_user: socket.assigns.current_user)
{:ok, pid} = Legion.start_link(MyApp.WriterAgent)
```

If you already build an `Ash.Scope` for your LiveViews, put the scope in
Vault instead of the bare user and pass `scope: Vault.get(:scope)` to the
actions. Actor, tenant and context then travel together and Ash and Legion
agree on who is asking.

## Don't hand records to the model

The Lua sandbox turns structs into tables with `Map.from_struct`, so an Ash
record passed through untouched drags along `__meta__`, `__metadata__`,
empty `aggregates` and `calculations` maps, an `Ash.NotLoaded` table for
every relationship you didn't load, and, more to the point, private and
`sensitive?` attributes. Ash redacts sensitive fields in `inspect` output.
The Lua boundary doesn't, and in the Elixir sandbox generated code can just
read the field off the struct.

`Map.take(record, @public_attributes)` takes care of both the token waste
and the leak. When the agent actually needs a loaded relationship or a
calculation, add it to the take list by hand.

## A few things to avoid

Don't allowlist `Ash`, `Ash.Query` or your domain module in the Elixir
sandbox. Once generated code can call `Ash.read!` itself it can pass whatever
`actor:` it likes, or `authorize?: false`. The Lua sandbox doesn't have this
problem, since a module that isn't a `Legion.Tool` exposes no functions
there.

Keep `show_policy_breakdowns?` off in production. The breakdown ends up in
the tool error, the tool error ends up in the conversation, and from there
it's one step away from the user.

Put a limit on reads inside the tool. Legion truncates tool results at
`max_message_length`, and a model reasoning over a table that was cut off
halfway is worse off than one that got fifty rows and knows it.

## Errors

Forbidden and Invalid errors are rescued and re-raised as sandbox errors
with the message intact, so the model sees something like
`attribute title is required` and can fix its call. Each retry costs a round
trip though (`max_retries` defaults to three), so it's cheaper to spell the
rules out in the moduledoc, as the example above does, than to let the model
discover them by failing.

## Calling an agent from an action

It works in the other direction too. A generic action can run an agent:

```elixir
action :summarize, :string do
  argument :text, :string, allow_nil?: false

  run fn input, _context ->
    case Legion.execute(MyApp.SummaryAgent, input.arguments.text) do
      {:ok, summary} -> {:ok, summary}
      {:cancel, reason} -> {:error, reason}
    end
  end
end
```

Ash takes its actor from the action options while Legion's tools take theirs
from Vault, so initialize Vault once at the front door from the same scope
you hand to Ash. Don't call `Vault.init` inside the action itself; it raises
if an ancestor process already did.

## Store, rate limiter, tenants

`Legion.Store.Postgres` and `Legion.RateLimiter.Postgres` want an
`Ecto.Repo`, and an `AshPostgres.Repo` is one, so point them at the repo you
already have. The store migration is an ordinary `Ecto.Migration` and can
live next to whatever `mix ash.codegen` generates.

Multitenancy needs nothing special. `tenant:` is an Ash option like
`actor:`, so keep it in Vault or inside the scope and pass it along the same
way.
