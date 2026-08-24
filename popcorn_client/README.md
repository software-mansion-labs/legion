# legion_popcorn_client

The browser half of `Legion.Sandbox.Popcorn`: an Elixir app cooked into an
AtomVM `.avm` bundle by [popcorn](https://hex.pm/packages/popcorn) 0.3.3.

Everything the sandbox serves from `priv/popcorn/` is a build output of this
directory. `priv/popcorn/` is gitignored - nothing in it is committed - so
it has to be built before legion can serve the sandbox, before
`mix hex.build`, and on every machine that runs legion from a path or git
dependency.

## Building `priv/popcorn`

    cd popcorn_client
    mix bundle

`mix bundle` produces the whole directory:

1. `deps.get` + `popcorn.cook` - compiles this app and the popcorn runtime
   library into `bundle.avm` (the code that runs in the visitor's browser)
   and copies it to `../priv/popcorn/bundle.avm`.
2. Vendors the browser runtime from the npm package
   `@swmansion/popcorn@0.3.3` (`npm pack`, Apache-2.0, see `NOTICE`):
   `index.mjs`, `popcorn.mjs`, `bridge.mjs`, `errors.mjs`, `types.mjs`,
   `iframe.mjs`, `AtomVM.mjs` and `AtomVM.wasm`. These are not produced by
   `popcorn.cook` and the popcorn hex package does not ship them.

Rerun it after changing anything under `lib/`, or after bumping the popcorn
version (keep the hex dep in `mix.exs` and the npm version in the vendor
step in sync - the JS runtime and the `.avm` must match).

## Toolchain

- **Erlang/OTP 26.0.2 + Elixir 1.17.3** - popcorn 0.3.3 compiles under
  nothing else. `.tool-versions` pins them for asdf; the pin is scoped to
  this directory and does not affect legion itself.
- **npm** - for the runtime vendor step.

## Layout

- `lib/legion_popcorn_client/` - the evaluator (`Code.eval_string` worker
  with per-session bindings) and the tool bridge (stub modules relaying
  tool calls to the server via `Popcorn.Wasm.send_event`).
- `config/config.exs` - `out_dir: "static"`, popcorn's cook target.
- `static/`, `_build/`, `deps/` - build workspace, gitignored.
