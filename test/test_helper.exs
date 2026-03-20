{:ok, _} = Application.ensure_all_started(:wallaby)
ExUnit.start()
ExUnit.configure(exclude: [:e2e])
