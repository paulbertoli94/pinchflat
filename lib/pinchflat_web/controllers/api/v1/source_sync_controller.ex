defmodule PinchflatWeb.Api.V1.SourceSyncController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Api

  def import(conn, %{"source_id" => source_id} = params) do
    youtube_ids = Map.get(params, "youtube_ids")

    with {:ok, source} <- Api.get_source(source_id),
         {:ok, imported_ids} <- Api.import_to_source(source, youtube_ids) do
      Logger.info("API import queued source_id=#{source.id} youtube_id_count=#{length(imported_ids)}")

      conn
      |> put_status(:accepted)
      |> json(%{
        source_id: source.id,
        status: "queued",
        imported_youtube_ids: imported_ids,
        expected_youtube_ids: imported_ids
      })
    else
      error -> render_error(conn, error)
    end
  end

  def sync(conn, %{"source_id" => source_id} = params) do
    youtube_ids = Map.get(params, "youtube_ids")

    with {:ok, source} <- Api.get_source(source_id),
         {:ok, normalized_ids} <- Api.sync_source(source, youtube_ids) do
      Logger.info("API sync queued source_id=#{source.id} youtube_id_count=#{length(normalized_ids)}")

      conn
      |> put_status(:accepted)
      |> json(%{
        source_id: source.id,
        status: "queued",
        expected_youtube_ids: normalized_ids
      })
    else
      error -> render_error(conn, error)
    end
  end

  def show_media_by_youtube_id(conn, %{"source_id" => source_id, "youtube_id" => youtube_id}) do
    with {:ok, source} <- Api.get_source(source_id),
         {:ok, item} <- Api.media_status_for_youtube_id(source, youtube_id) do
      json(conn, item)
    else
      error -> render_error(conn, error)
    end
  end

  def media_status(conn, %{"source_id" => source_id} = params) do
    youtube_ids = Map.get(params, "youtube_ids")

    with {:ok, source} <- Api.get_source(source_id),
         {:ok, items} <- Api.batch_media_status(source, youtube_ids) do
      json(conn, %{items: items})
    else
      error -> render_error(conn, error)
    end
  end

  defp render_error(conn, {:error, :source_not_found}) do
    error(conn, :not_found, "source_not_found", "Source not found")
  end

  defp render_error(conn, {:error, :media_not_found}) do
    error(conn, :not_found, "media_not_found", "Media not found")
  end

  defp render_error(conn, {:error, :source_disabled}) do
    error(conn, :conflict, "source_disabled", "Source is disabled")
  end

  defp render_error(conn, {:error, :source_not_playlist}) do
    error(conn, :conflict, "source_not_playlist", "Source is not a playlist")
  end

  defp render_error(conn, {:error, :empty_youtube_ids}) do
    error(conn, :unprocessable_entity, "empty_youtube_ids", "youtube_ids must not be empty")
  end

  defp render_error(conn, {:error, :too_many_youtube_ids}) do
    error(conn, :unprocessable_entity, "too_many_youtube_ids", "youtube_ids exceeds the maximum batch size", %{
      max: Api.max_youtube_ids()
    })
  end

  defp render_error(conn, {:error, validation_error})
       when validation_error in [:invalid_youtube_id, :invalid_youtube_ids] do
    error(conn, :unprocessable_entity, "invalid_youtube_id", "youtube_ids must contain valid YouTube IDs")
  end

  defp render_error(conn, {:error, {:enqueue_failed, reason}}) do
    Logger.error("API sync enqueue failed: #{inspect(reason)}")
    error(conn, :internal_server_error, "enqueue_failed", "Failed to enqueue indexing task")
  end

  defp render_error(conn, {:error, :google_not_connected}) do
    error(conn, :conflict, "google_not_connected", "Google account is not connected in Pinchflat settings")
  end

  defp render_error(conn, {:error, :google_refresh_token_missing}) do
    error(conn, :bad_gateway, "google_refresh_token_missing", "Google did not return a refresh token")
  end

  defp render_error(conn, {:error, :google_access_token_missing}) do
    error(conn, :bad_gateway, "google_access_token_missing", "Google did not return an access token")
  end

  defp render_error(conn, {:error, :google_reauthorization_required}) do
    error(
      conn,
      :conflict,
      "google_reauthorization_required",
      "Google authorization expired or was revoked. Reconnect Google in Pinchflat settings."
    )
  end

  defp render_error(conn, {:error, {:youtube_api_error, reason}}) do
    Logger.error("YouTube API import failed: #{inspect(reason)}")
    error(conn, :bad_gateway, "youtube_api_error", "YouTube API request failed")
  end

  defp render_error(conn, error) do
    Logger.error("Unexpected API error: #{inspect(error)}")
    error(conn, :internal_server_error, "internal_server_error", "Internal server error")
  end

  defp error(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
