defmodule LuaExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :lua_example,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:kettlecorn, path: "../../../host", runtime: false}, {:lua, "1.0.2"}]
    ]
  end

  def application do
    [mod: {LuaExample.Application, []}, extra_applications: [:logger]]
  end
end
