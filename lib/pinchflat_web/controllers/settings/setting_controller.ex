defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  alias Pinchflat.Settings

  def show(conn, _params) do
    setting = Settings.record()
    changeset = Settings.change_setting(setting)

    render_settings(conn, changeset)
  end

  def update(conn, %{"setting" => setting_params}) do
    setting = Settings.record()

    case Settings.update_setting(setting, setting_params) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Settings updated successfully.")
        |> redirect(to: ~p"/settings")

      {:error, %Ecto.Changeset{} = changeset} ->
        render_settings(conn, changeset)
    end
  end

  def app_info(conn, _params) do
    render(conn, "app_info.html")
  end

  def download_logs(conn, _params) do
    log_path = Application.get_env(:pinchflat, :log_path)

    if log_path && File.exists?(log_path) do
      send_download(conn, {:file, log_path}, filename: "pinchflat-logs-#{Date.utc_today()}.txt")
    else
      conn
      |> put_flash(:error, "Log file couldn't be found")
      |> redirect(to: ~p"/app_info")
    end
  end

  defp render_settings(conn, changeset) do
    render(conn, "show.html",
      changeset: changeset,
      api_connection_payload: api_connection_payload(conn),
      api_base_url: api_base_url(conn),
      api_token_configured?: api_token_configured?()
    )
  end

  defp api_connection_payload(conn) do
    case Application.get_env(:pinchflat, :api_token) do
      token when is_binary(token) and token != "" ->
        Jason.encode!(%{
          type: "pinchflat_api_connection",
          version: 1,
          api_base_url: api_base_url(conn),
          token: token
        })

      _ ->
        nil
    end
  end

  defp api_base_url(conn) do
    conn
    |> url(~p"/")
    |> URI.parse()
    |> Map.put(:path, "/api/v1")
    |> Map.put(:query, nil)
    |> URI.to_string()
  end

  defp api_token_configured? do
    case Application.get_env(:pinchflat, :api_token) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end
end
