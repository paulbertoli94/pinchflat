defmodule PinchflatWeb.Settings.SettingController do
  use PinchflatWeb, :controller

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Settings
  alias Pinchflat.Sources.Source
  alias Pinchflat.YouTube.OAuthClient

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

  def google_connect(conn, _params) do
    setting = Settings.record()

    if OAuthClient.configured?(setting) do
      state = oauth_state()
      redirect_uri = google_redirect_uri(conn)

      conn
      |> put_session(:google_oauth_state, state)
      |> redirect(external: OAuthClient.authorize_url(setting, redirect_uri, state))
    else
      conn
      |> put_flash(:error, "Set Google OAuth Client ID and Client Secret first.")
      |> redirect(to: ~p"/settings")
    end
  end

  def google_callback(conn, %{"code" => code, "state" => state}) do
    setting = Settings.record()

    with ^state <- get_session(conn, :google_oauth_state),
         {:ok, _setting} <- OAuthClient.exchange_code(setting, code, google_redirect_uri(conn)) do
      conn
      |> delete_session(:google_oauth_state)
      |> put_flash(:info, "Google account connected successfully.")
      |> redirect(to: ~p"/settings")
    else
      _error ->
        conn
        |> delete_session(:google_oauth_state)
        |> put_flash(:error, "Google account connection failed.")
        |> redirect(to: ~p"/settings")
    end
  end

  def google_callback(conn, _params) do
    conn
    |> put_flash(:error, "Google account connection failed.")
    |> redirect(to: ~p"/settings")
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
      google_redirect_uri: google_redirect_uri(conn),
      google_oauth_configured?: OAuthClient.configured?(Settings.record()),
      google_oauth_connected?: OAuthClient.connected?(Settings.record()),
      api_token_configured?: api_token_configured?()
    )
  end

  defp api_connection_payload(conn) do
    case Application.get_env(:pinchflat, :api_token) do
      token when is_binary(token) and token != "" ->
        sources = api_sources()

        payload =
          Jason.encode!(%{
            type: "pinchflat_api_connection",
            version: 3,
            api_base_url: api_base_url(conn),
            token: token,
            capabilities: %{
              sync: true,
              media_status: true,
              youtube_import: OAuthClient.connected?(Settings.record())
            },
            default_source_id: default_source_id(sources),
            sources: sources
          })

        "tempus://pinchflat/connect##{URI.encode(payload)}"

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

  defp api_sources do
    Source
    |> where([s], s.enabled == true and s.collection_type == :playlist)
    |> order_by([s], asc: s.custom_name)
    |> Repo.all()
    |> Enum.map(fn source ->
      %{
        id: source.id,
        uuid: source.uuid,
        name: source.custom_name,
        collection_type: source.collection_type,
        playlist_id: source.collection_id,
        original_url: source.original_url,
        media_profile_id: source.media_profile_id
      }
    end)
  end

  defp default_source_id(sources) do
    case sources do
      [%{id: id}] -> id
      _ -> nil
    end
  end

  defp api_token_configured? do
    case Application.get_env(:pinchflat, :api_token) do
      token when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  defp google_redirect_uri(conn) do
    url(conn, ~p"/settings/google/callback")
  end

  defp oauth_state do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
