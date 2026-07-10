defmodule PinchflatWeb.Api.V1.YoutubeController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Api
  alias Pinchflat.Youtube.Search

  def search(conn, %{"source_id" => source_id} = params) do
    with {:ok, source} <- Api.get_source(source_id),
         {:ok, items} <- Search.search(Map.get(params, "q"), max_results: Map.get(params, "max_results", 10)),
         {:ok, statuses} <- Api.batch_media_status(source, Enum.map(items, & &1.youtube_id)) do
      json(conn, %{items: merge_statuses(items, statuses, source.id)})
    else
      error -> render_error(conn, error)
    end
  end

  def history(conn, %{"source_id" => source_id} = params) do
    with {:ok, source} <- Api.get_source(source_id),
         {:ok, limit} <- normalize_limit(Map.get(params, "limit", 25)),
         {:ok, items} <- Api.recent_media_for_source(source, limit: limit) do
      json(conn, %{items: items})
    else
      error -> render_error(conn, error)
    end
  end

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> normalize_limit(value)
      _ -> {:error, :invalid_limit}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit in 1..100 do
    {:ok, limit}
  end

  defp normalize_limit(_limit), do: {:error, :invalid_limit}

  defp merge_statuses(items, statuses, source_id) do
    statuses_by_id = Map.new(statuses, &{&1.youtube_id, &1})

    Enum.map(items, fn item ->
      status = Map.fetch!(statuses_by_id, item.youtube_id)

      Map.put(item, :pinchflat_status, %{
        source_id: source_id,
        status: status.status,
        in_source: status.status != "unknown",
        already_downloaded: status.status == "completed",
        media_id: status.media_id,
        media_uuid: status.media_uuid,
        downloaded_at: status.downloaded_at,
        filepath: status.filepath,
        last_error: status.last_error
      })
    end)
  end

  defp render_error(conn, {:error, :youtube_api_key_not_configured}) do
    error(conn, :conflict, "youtube_api_key_not_configured", "YouTube API key is not configured in Pinchflat settings")
  end

  defp render_error(conn, {:error, :source_not_found}) do
    error(conn, :not_found, "source_not_found", "Source not found")
  end

  defp render_error(conn, {:error, :empty_query}) do
    error(conn, :unprocessable_entity, "empty_query", "Search query must not be empty")
  end

  defp render_error(conn, {:error, :query_too_long}) do
    error(conn, :unprocessable_entity, "query_too_long", "Search query is too long")
  end

  defp render_error(conn, {:error, :invalid_max_results}) do
    error(conn, :unprocessable_entity, "invalid_max_results", "max_results must be between 1 and 25")
  end

  defp render_error(conn, {:error, :invalid_limit}) do
    error(conn, :unprocessable_entity, "invalid_limit", "limit must be between 1 and 100")
  end

  defp render_error(conn, {:error, reason}) do
    Logger.error("YouTube search failed: #{inspect(reason)}")
    error(conn, :bad_gateway, "youtube_search_failed", "YouTube search failed")
  end

  defp error(conn, status, code, message, details \\ %{}) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
