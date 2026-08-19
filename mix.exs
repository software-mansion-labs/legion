defmodule Legion.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/software-mansion-labs/legion"

  def project do
    [
      app: :legion,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      # Hex
      package: package(),
      description: """
      Legion is an Elixir-native framework for building AI agents
      """,
      # Docs
      name: "Legion",
      docs: [
        main: "Legion",
        api_reference: false,
        source_ref: "v#{@version}",
        source_url: @source_url,
        extra_section: "GUIDES",
        formatters: ["html"],
        extras: [
          "LICENSE",
          "guides/sandboxes.md": [title: "Sandboxes"],
          "CHANGELOG.md": [title: "Changelog"]
        ],
        groups_for_modules: groups_for_modules()
      ]
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp groups_for_modules do
    [
      Core: [
        Legion,
        Legion.Agent,
        Legion.Tool,
        Legion.Store,
        Legion.Store.Payload,
        Legion.Store.Postgres,
        Legion.Store.Migration.Postgres
      ],
      "Rate Limiting": [
        Legion.RateLimiter,
        Legion.RateLimiter.Policy,
        Legion.RateLimiter.Postgres,
        Legion.RateLimiter.Migration.Postgres
      ],
      Runtime: [Legion.AgentServer, Legion.Executor, Legion.Recovery, ~r/^Legion\.Sandbox/],
      Tools: [~r/^Legion\.Tools\./],
      Internals: [
        Legion.AgentIndex,
        Legion.AgentPrompt,
        Legion.SourceRegistry,
        Legion.Telemetry
      ]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:req_llm, "~> 1.20"},
      {:vault, "~> 0.2"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:lua, "~> 1.0"},

      # Optional
      {:postgrex, "~> 0.22", optional: true},

      # Test and Dev
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Software Mansion"],
      licenses: ["MIT"],
      links: %{
        Website: "https://swmansion.com/",
        Changelog: "#{@source_url}/blob/main/CHANGELOG.md",
        GitHub: @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*)
    ]
  end

  defp aliases do
    [
      release: [
        "cmd git tag v#{@version}",
        "cmd git push",
        "cmd git push --tags",
        "hex.publish --yes"
      ],
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo --strict",
        "sobelow --exit --skip",
        "test --exclude integration"
      ]
    ]
  end
end
