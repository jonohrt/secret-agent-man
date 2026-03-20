defmodule SamWeb.FeatureCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      @endpoint SamWeb.Endpoint
      use SamWeb, :verified_routes

      import Wallaby.Query
    end
  end
end
