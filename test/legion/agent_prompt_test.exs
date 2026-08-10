defmodule Legion.AgentPromptTest do
  use ExUnit.Case

  alias Legion.AgentPrompt
  alias Legion.Test.Support.{HackerNewsAgent, MathAgent, NoToolAgent}

  defmodule JasonAgent do
    @moduledoc "Agent that uses Jason as a 3rd party tool."
    use Legion.Agent

    def tools, do: [Jason]
  end

  describe "system_prompt/1" do
    test "includes agent moduledoc" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "An agent that does math."
    end

    test "includes the sandbox language" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "Lua"
    end

    test "includes custom description when description/0 is overridden" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "MathTool — performs math operations using integer arithmetic only."
      refute prompt =~ "defmodule Legion.Test.Support.MathTool"
    end

    test "includes source code as default description" do
      prompt = AgentPrompt.system_prompt(HackerNewsAgent)
      assert prompt =~ "defmodule Legion.Test.Support.HackerNewsTool"
      assert prompt =~ "def fetch_posts"
    end

    test "includes Available Tools section header" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt =~ "## Available Tools"
    end

    test "no tools section when agent has no tools" do
      prompt = AgentPrompt.system_prompt(NoToolAgent)
      refute prompt =~ "## Available Tools"
    end

    test "result is trimmed" do
      prompt = AgentPrompt.system_prompt(MathAgent)
      assert prompt == String.trim(prompt)
    end

    test "includes 3rd party library source when listed in tools" do
      prompt = AgentPrompt.system_prompt(JasonAgent)
      assert prompt =~ "## Available Tools"
      assert prompt =~ "defmodule Jason"
    end
  end
end
