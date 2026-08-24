defmodule LegionPopcornClient.MixProject do
  use Mix.Project

  # Hex dep and npm runtime must stay on the same version: the JS side and
  # the cooked .avm speak a matching protocol.
  @popcorn_version "0.3.3"
  @npm_package "@swmansion/popcorn"
  @runtime_files ~w(index.mjs popcorn.mjs bridge.mjs errors.mjs types.mjs iframe.mjs AtomVM.mjs AtomVM.wasm)

  def project do
    [
      app: :legion_popcorn_client,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: [{:popcorn, @popcorn_version}],
      aliases: [bundle: ["deps.get", "popcorn.cook", &copy_bundle/1, &vendor_runtime/1]]
    ]
  end

  def application do
    [mod: {LegionPopcornClient.Application, []}, extra_applications: [:logger]]
  end

  defp copy_bundle(_args) do
    File.mkdir_p!(dest())
    File.cp!("static/bundle.avm", Path.join(dest(), "bundle.avm"))
    Mix.shell().info("bundle.avm copied to #{dest()}")
  end

  defp vendor_runtime(_args) do
    spec = "#{@npm_package}@#{@popcorn_version}"
    work_dir = Path.join(Mix.Project.build_path(), "npm")
    File.rm_rf!(work_dir)
    File.mkdir_p!(work_dir)

    unless System.find_executable("npm"),
      do: Mix.raise("npm is required to vendor the #{spec} browser runtime")

    {output, 0} = System.cmd("npm", ["pack", spec, "--pack-destination", work_dir])
    tarball = Path.join(work_dir, String.trim(output))

    :ok =
      :erl_tar.extract(String.to_charlist(tarball), [
        :compressed,
        {:cwd, String.to_charlist(work_dir)}
      ])

    for file <- @runtime_files do
      File.cp!(Path.join([work_dir, "package", "dist", file]), Path.join(dest(), file))
    end

    File.write!(Path.join(dest(), "NOTICE"), notice())
    Mix.shell().info("#{spec} runtime vendored to #{dest()}")
  end

  defp dest, do: Path.expand("../priv/popcorn", __DIR__)

  defp notice do
    """
    #{Enum.join(@runtime_files, ", ")} are the built dist of the npm package
    #{@npm_package} #{@popcorn_version} (c) Software Mansion, Apache-2.0.
    bundle.avm is built from ../../popcorn_client with popcorn #{@popcorn_version}.
    """
  end
end
