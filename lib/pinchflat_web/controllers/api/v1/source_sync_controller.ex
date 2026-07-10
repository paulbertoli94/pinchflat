defmodule PinchflatWeb.Api.V1.SourceSyncController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Api

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
