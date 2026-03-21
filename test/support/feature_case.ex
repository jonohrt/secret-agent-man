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

  setup _context do
    Application.put_env(:wallaby, :base_url, SamWeb.Endpoint.url())
    {:ok, session} = Wallaby.start_session()
    {:ok, session: session}
  end
end
