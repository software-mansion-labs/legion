defmodule Legion.SourceRegistry do
  @moduledoc """
  Compile-time registry of source code for external modules.

  Tools expose their source via `description/0` (injected by `use Legion.Tool`)
  and agents expose theirs via the auto-generated `moduledoc/0` (injected by
  `use Legion.Agent`). This registry is only needed for external modules
  (e.g. `Req`) configured via:

      config :legion, extra_source_modules: [Req]
  """

  @extra_modules Application.compile_env(:legion, :extra_source_modules, [])

  @sources Map.new(@extra_modules, fn module ->
             path = module.__info__(:compile)[:source] |> to_string()
             {module, File.read!(path)}
           end)

  def sources, do: @sources

  def source(module) when is_map_key(@sources, module) do
    {:ok, Map.fetch!(@sources, module)}
  end

  def source(_module), do: {:error, :not_registered}

  def source!(module) do
    case source(module) do
      {:ok, source} ->
        source

      {:error, :not_registered} ->
        raise "Module #{inspect(module)} is not registered in SourceRegistry"
    end
  end
end
