defmodule PinchflatWeb.SettingControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Utils.FilesystemUtils

  describe "show settings" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200) =~ "Settings"
    end

    test "renders Tempus API pairing when API token is configured", %{conn: conn} do
      old_token = Application.get_env(:pinchflat, :api_token)
      on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)
      Application.put_env(:pinchflat, :api_token, "test-token")
      source = source_fixture(collection_type: "playlist", custom_name: "Liked", collection_id: "PL123")
      source_fixture(collection_type: "playlist", custom_name: "Disabled", enabled: false)
      source_fixture(collection_type: "channel", custom_name: "Channel")

      conn = get(conn, ~p"/settings")
      response = html_response(conn, 200)
      payload = decoded_qr_payload(response)

      assert response =~ "API Access"
      assert response =~ "data-api-connection-qr"
      assert response =~ "tempus://pinchflat/connect#"
      assert payload["type"] == "pinchflat_api_connection"
      assert payload["version"] == 2
      assert payload["token"] == "test-token"
      assert payload["api_base_url"] == "http://www.example.com/api/v1"
      assert payload["default_source_id"] == source.id

      assert [
               %{
                 "id" => source_id,
                 "name" => "Liked",
                 "collection_type" => "playlist",
                 "playlist_id" => "PL123"
               }
             ] = payload["sources"]

      assert source_id == source.id
    end

    test "renders API token setup message when API token is not configured", %{conn: conn} do
      old_token = Application.get_env(:pinchflat, :api_token)
      on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)
      Application.put_env(:pinchflat, :api_token, nil)

      conn = get(conn, ~p"/settings")

      assert html_response(conn, 200) =~ "Set PINCHFLAT_API_TOKEN and restart Pinchflat to enable API pairing."
    end
  end

  describe "update settings" do
    test "saves and redirects when data is valid", %{conn: conn} do
      update_attrs = %{apprise_server: "test://server"}

      conn = put(conn, ~p"/settings", setting: update_attrs)
      assert redirected_to(conn) == ~p"/settings"

      conn = get(conn, ~p"/settings")
      assert html_response(conn, 200) =~ update_attrs[:apprise_server]
    end
  end

  describe "app_info" do
    test "renders the page", %{conn: conn} do
      conn = get(conn, ~p"/app_info")

      assert html_response(conn, 200) =~ "App Info"
    end
  end

  describe "download_logs" do
    test "downloads logs", %{conn: conn} do
      log_path = Path.join([System.tmp_dir!(), "pinchflat", "data", "pinchflat.log"])
      FilesystemUtils.write_p(log_path, "test log data")
      Application.put_env(:pinchflat, :log_path, log_path)

      conn = get(conn, ~p"/download_logs")

      assert response(conn, 200) =~ "test log data"

      Application.put_env(:pinchflat, :log_path, nil)
    end

    test "redirects when log file is not found", %{conn: conn} do
      conn = get(conn, ~p"/download_logs")

      assert redirected_to(conn) == ~p"/app_info"
      assert conn.assigns[:flash]["error"] == "Log file couldn't be found"
    end
  end

  defp decoded_qr_payload(response) do
    [{"canvas", attrs, _children}] =
      response
      |> Floki.parse_document!()
      |> Floki.find("[data-api-connection-qr]")

    qr_content =
      attrs
      |> Map.new()
      |> Map.fetch!("data-qr-content")

    "tempus://pinchflat/connect#" <> encoded_payload = qr_content

    encoded_payload
    |> URI.decode()
    |> Jason.decode!()
  end
end
