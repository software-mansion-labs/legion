defmodule Legion.AgentPrompt do
  @moduledoc """
  This module is responsible for generating prompts for agents based on their definitions and the tools they have access to.
  """

  @template_path Path.join(__DIR__, "prompts/system_prompt.eex")
  @external_resource @template_path
  @template EEx.compile_file(@template_path)

  def system_prompt(agent, config \\ nil) do
    if function_exported?(agent, :system_prompt, 0) do
      agent.system_prompt()
    else
      build_system_prompt(agent, config || agent.config())
    end
  end

  defp build_system_prompt(agent, config) do
    tool_contents = Enum.map(agent.tools(), &tool_description/1)
    description = agent.moduledoc()
    binding_scope = Map.get(config, :binding_scope, :turn)
    sandbox = Map.get(config, :sandbox, Legion.Sandbox.Elixir)
    prompt_info = sandbox.prompt_info()

    {result, _} =
      Code.eval_quoted(@template,
        description: description,
        tool_contents: tool_contents,
        action_types: agent.action_types(),
        plain_text_result?: match?(%{"type" => "string"}, agent.output_schema()),
        binding_scope: binding_scope,
        language: prompt_info.language,
        constraints: String.trim_trailing(prompt_info.constraints),
        tool_usage: prompt_info.tool_usage
      )

    String.trim(result)
  end

  defp tool_description(module) do
    Code.ensure_loaded!(module)

    content =
      if function_exported?(module, :description, 0) do
        module.description()
      else
        Legion.SourceRegistry.source!(module)
      end

    short_name = module |> Module.split() |> List.last()
    {short_name, String.trim(content)}
  end
end
