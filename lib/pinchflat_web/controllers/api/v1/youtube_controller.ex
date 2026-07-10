defmodule PinchflatWeb.Api.V1.YoutubeController do
  use PinchflatWeb, :controller

  require Logger

  alias Pinchflat.Youtube.Search

  def search(conn, params) do
    case Search.search(Map.get(params, "q"), max_results: Map.get(params, "max_results", 10)) do
      {:ok, items} -> json(conn, %{items: items})
      error -> render_error(conn, error)
    end
  end

  defp render_error(conn, {:error, :youtube_api_key_not_configured}) do
    error(conn, :conflict, "youtube_api_key_not_configured", "YouTube API key is not configured in Pinchflat settings")
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
