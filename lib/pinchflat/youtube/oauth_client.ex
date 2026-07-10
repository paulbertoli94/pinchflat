defmodule Pinchflat.Youtube.OauthClient do
  @moduledoc """
  Handles Google OAuth and YouTube playlist writes for server-side API imports.
  """

  alias Pinchflat.Settings
  alias Pinchflat.Settings.Setting
  alias Pinchflat.Sources.Source

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @playlist_items_url "https://www.googleapis.com/youtube/v3/playlistItems"
  @youtube_scope "https://www.googleapis.com/auth/youtube"

  def authorize_url(%Setting{} = setting, redirect_uri, state) do
    query =
      URI.encode_query(%{
        client_id: setting.google_oauth_client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        scope: @youtube_scope,
        access_type: "offline",
        prompt: "consent",
        state: state
      })

    "#{@authorize_url}?#{query}"
  end

  def configured?(%Setting{} = setting) do
    present?(setting.google_oauth_client_id) and present?(setting.google_oauth_client_secret)
  end

  def connected?(%Setting{} = setting) do
    configured?(setting) and present?(setting.google_oauth_refresh_token)
  end

  def exchange_code(%Setting{} = setting, code, redirect_uri) do
    body =
      URI.encode_query(%{
        code: code,
        client_id: setting.google_oauth_client_id,
        client_secret: setting.google_oauth_client_secret,
        redirect_uri: redirect_uri,
        grant_type: "authorization_code"
      })

    with {:ok, response} <- http_client().post(@token_url, body, form_headers(), []),
         {:ok, payload} <- Jason.decode(response),
         {:ok, refresh_token} <- fetch_refresh_token(payload) do
      Settings.update_setting(setting, %{
        google_oauth_refresh_token: refresh_token,
        google_oauth_connected_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end
  end

  def insert_playlist_items(%Source{} = source, youtube_ids) do
    setting = Settings.record()

    with :ok <- ensure_connected(setting),
         {:ok, access_token} <- refresh_access_token(setting) do
      youtube_ids
      |> Enum.reduce_while({:ok, []}, fn youtube_id, {:ok, imported_ids} ->
        case insert_playlist_item(source.collection_id, youtube_id, access_token) do
          :ok -> {:cont, {:ok, [youtube_id | imported_ids]}}
          {:error, :already_in_playlist} -> {:cont, {:ok, [youtube_id | imported_ids]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, imported_ids} -> {:ok, Enum.reverse(imported_ids)}
        error -> error
      end
    end
  end

  defp refresh_access_token(%Setting{} = setting) do
    body =
      URI.encode_query(%{
        client_id: setting.google_oauth_client_id,
        client_secret: setting.google_oauth_client_secret,
        refresh_token: setting.google_oauth_refresh_token,
        grant_type: "refresh_token"
      })

    with {:ok, response} <- http_client().post(@token_url, body, form_headers(), []),
         {:ok, payload} <- Jason.decode(response) do
      fetch_access_token(payload)
    end
  end

  defp insert_playlist_item(playlist_id, youtube_id, access_token) do
    body =
      Jason.encode!(%{
        snippet: %{
          playlistId: playlist_id,
          resourceId: %{
            kind: "youtube#video",
            videoId: youtube_id
          }
        }
      })

    url = "#{@playlist_items_url}?part=snippet"
    headers = [{"authorization", "Bearer #{access_token}"}, {"content-type", "application/json"}]

    case http_client().post(url, body, headers, []) do
      {:ok, _response} -> :ok
      {:error, error} when is_binary(error) -> youtube_error(error)
      {:error, error} -> {:error, {:youtube_api_error, error}}
    end
  end

  defp youtube_error(error) do
    if String.contains?(error, "videoAlreadyInPlaylist") do
      {:error, :already_in_playlist}
    else
      {:error, {:youtube_api_error, error}}
    end
  end

  defp ensure_connected(%Setting{} = setting) do
    if connected?(setting), do: :ok, else: {:error, :google_not_connected}
  end

  defp fetch_refresh_token(%{"refresh_token" => token}) when is_binary(token) and token != "", do: {:ok, token}
  defp fetch_refresh_token(_payload), do: {:error, :google_refresh_token_missing}

  defp fetch_access_token(%{"access_token" => token}) when is_binary(token) and token != "", do: {:ok, token}
  defp fetch_access_token(_payload), do: {:error, :google_access_token_missing}

  defp form_headers do
    [{"content-type", "application/x-www-form-urlencoded"}, {"accept", "application/json"}]
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
