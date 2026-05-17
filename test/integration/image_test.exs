defmodule Legion.Integration.ImageTest do
  @moduledoc """
  Integration test: send an image to a vision-capable model.

  Run with:

      mix test test/integration/image_test.exs --include integration
  """
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart

  @moduletag :integration
  @moduletag timeout: 60_000

  defmodule ImageAgent do
    @moduledoc "Describes what is in an image."
    use Legion.Agent

    def config, do: %{model: "openai:gpt-4o-mini"}

    def system_prompt do
      "You describe images. For every user message, return a one-sentence " <>
        "description of the dominant color and contents of the image via the " <>
        "`return` action. Never use the `done` action."
    end
  end

  setup do
    unless System.get_env("OPENAI_API_KEY"), do: raise("OPENAI_API_KEY not set")
    :ok
  end

  # 1x1 red pixel PNG
  @red_pixel_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

  test "describes an image sent as binary data" do
    red_pixel_png = Base.decode64!(@red_pixel_base64)

    message =
      {:multipart,
       [
         ContentPart.text("Describe what you see in this image in one sentence."),
         ContentPart.image(red_pixel_png, "image/png")
       ]}

    {:ok, result} = Legion.execute(ImageAgent, message)

    assert is_binary(result)
    assert String.downcase(result) =~ "red"
  end

  test "describes an image sent via {:image, data, media_type} shorthand" do
    red_pixel_png = Base.decode64!(@red_pixel_base64)

    {:ok, result} = Legion.execute(ImageAgent, {:image, red_pixel_png, "image/png"})

    assert is_binary(result)
    assert String.downcase(result) =~ "red"
  end

  test "describes an image sent via {:image_url, url} shorthand" do
    data_url = "data:image/png;base64,#{@red_pixel_base64}"

    {:ok, result} = Legion.execute(ImageAgent, {:image_url, data_url})

    assert is_binary(result)
    assert String.downcase(result) =~ "red"
  end
end
