defmodule PinchflatWeb.Api.V1.YoutubeController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Api
  alias Pinchflat.Youtube.Search

  def search(conn, %{"source_id" => source_id} = params) do
    with {:ok, source} <- Api.get_source(source_id),
         {:ok, items} <- Search.search(Map.get(params, "q"), max_results: Map.get(params, "max_results", 10)),
         {:ok, statuses} <- statuses_for_items(source, items) do
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
      case statuses_by_id[Map.get(item, :youtube_id)] do
        nil -> item
        status -> Map.put(item, :pinchflat_status, pinchflat_status(status, source_id))
      end
    end)
  end

  defp statuses_for_items(source, items) do
    youtube_ids =
      items
      |> Enum.map(&Map.get(&1, :youtube_id))
      |> Enum.filter(&valid_youtube_id?/1)

    case youtube_ids do
      [] -> {:ok, []}
      ids -> Api.batch_media_status(source, ids)
    end
  end

  defp valid_youtube_id?(youtube_id), do: is_binary(youtube_id) and Regex.match?(~r/^[A-Za-z0-9_-]{11}$/, youtube_id)

  defp pinchflat_status(status, source_id) do
    %{
      source_id: source_id,
      status: status.status,
      in_source: status.status != "unknown",
      already_downloaded: status.status == "completed",
      media_id: status.media_id,
      media_uuid: status.media_uuid,
      downloaded_at: status.downloaded_at,
      filepath: status.filepath,
      last_error: status.last_error
    }
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
