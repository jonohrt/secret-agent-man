defmodule SamWeb.Components.DirectoryPickerTest do
  use SamWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias SamWeb.Components.DirectoryPicker

  @tag :tmp_dir
  test "renders base path and MRU chips", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "apps/api"))
    File.mkdir_p!(Path.join(tmp_dir, "apps/web"))

    assigns = %{
      id: "picker-test",
      base_path: tmp_dir,
      mru_paths: [Path.join(tmp_dir, "apps/api"), Path.join(tmp_dir, "apps/web")],
      selected_path: tmp_dir
    }

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "apps/api"
    assert html =~ "apps/web"
  end

  @tag :tmp_dir
  test "lists only directories, not files", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "src"))
    File.write!(Path.join(tmp_dir, "mix.exs"), "")

    assigns = %{
      id: "picker-test",
      base_path: tmp_dir,
      mru_paths: [],
      selected_path: tmp_dir,
      browsing: true,
      current_dir: tmp_dir
    }

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "src"
    refute html =~ "mix.exs"
  end

  @tag :tmp_dir
  test "hides dotfiles", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.mkdir_p!(Path.join(tmp_dir, "lib"))

    assigns = %{
      id: "picker-test",
      base_path: tmp_dir,
      mru_paths: [],
      selected_path: tmp_dir,
      browsing: true,
      current_dir: tmp_dir
    }

    html = render_component(DirectoryPicker, assigns)

    assert html =~ "lib"
    refute html =~ ".git"
  end
end
