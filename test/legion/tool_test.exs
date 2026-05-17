defmodule Legion.ToolTest do
  use ExUnit.Case, async: true

  describe "extract_module_source/2" do
    test "extracts a single module from a file" do
      code =
        String.trim_trailing("""
        defmodule MyApp.Greeter do
          def hello, do: "hi"
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.Greeter) == code
    end

    test "extracts the correct module when multiple modules exist" do
      code = """
      defmodule MyApp.First do
        def one, do: 1
      end

      defmodule MyApp.Second do
        def two, do: 2
      end
      """

      assert Legion.Tool.extract_module_source(code, MyApp.Second) ==
               "defmodule MyApp.Second do\n  def two, do: 2\nend"
    end

    test "handles nested do/end blocks" do
      code =
        String.trim_trailing("""
        defmodule MyApp.Nested do
          def run do
            if true do
              :ok
            end
          end
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.Nested) == code
    end

    test "raises when module is not found" do
      code = """
      defmodule Other do
        def x, do: 1
      end
      """

      assert_raise RuntimeError, ~r/Could not find/, fn ->
        Legion.Tool.extract_module_source(code, MyApp.Missing)
      end
    end

    test "handles fn blocks inside the module" do
      code =
        String.trim_trailing("""
        defmodule MyApp.WithFn do
          def run do
            Enum.map([1], fn x ->
              x + 1
            end)
          end
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.WithFn) == code
    end

    test "extracts outer module from nested module file" do
      code =
        String.trim_trailing("""
        defmodule MyApp.Outer do
          defmodule Inner do
            def inner_fn, do: :inner
          end

          def outer_fn, do: :outer
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.Outer) == code
    end

    test "raises for shorthand nested module name" do
      code = """
      defmodule MyApp.Outer do
        defmodule Inner do
          def inner_fn, do: :inner
        end
      end
      """

      assert_raise RuntimeError, ~r/Could not find/, fn ->
        Legion.Tool.extract_module_source(code, MyApp.Outer.Inner)
      end
    end

    test "ignores do/end inside strings and comments" do
      code =
        String.trim_trailing("""
        defmodule MyApp.Strings do
          def example do
            # this end should not count
            x = "do not end this"
            x
          end
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.Strings) == code
    end

    test "ignores do/end inside heredocs" do
      code =
        String.trim_trailing("""
        defmodule MyApp.Heredoc do
          @moduledoc \"\"\"
          Use this tool to end the session.
          You can also do things with it.
          \"\"\"

          def hello, do: :hi
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.Heredoc) == code
    end

    test "ignores do/end inside single-quoted heredocs" do
      code =
        String.trim_trailing("""
        defmodule MyApp.CharHeredoc do
          @moduledoc \"\"\"
          wrapper
          \"\"\"

          def chars do
            'this end should not count'
          end
        end
        """)

      assert Legion.Tool.extract_module_source(code, MyApp.CharHeredoc) == code
    end
  end
end
