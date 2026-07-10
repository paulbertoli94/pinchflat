defmodule Pinchflat.Youtube.Search do
  @moduledoc """
  Server-side YouTube search for API clients.
  """

  alias Pinchflat.Settings

  @max_results 10
  @max_query_length 120

  def enabled?, do: Enum.any?(api_keys())

  def search(query, opts \\ []) do
    with :ok <- validate_enabled(),
         {:ok, query} <- normalize_query(query),
         {:ok, max_results} <- normalize_max_results(Keyword.get(opts, :max_results, @max_results)),
         {:ok, response} <- request(query, max_results),
         {:ok, payload} <- Jason.decode(response) do
      {:ok, parse_items(payload)}
    end
  end

  defp request(query, max_results) do
    query
    |> endpoint(max_results)
    |> http_client().get(accept: "application/json")
  end

  defp endpoint(query, max_results) do
    "https://youtube.googleapis.com/youtube/v3/search?" <>
      URI.encode_query(%{
        part: "snippet",
        type: "video",
        maxResults: max_results,
        q: query,
        key: next_api_key()
      })
  end

  defp parse_items(payload) do
    payload
    |> Map.get("items", [])
    |> Enum.map(&parse_item/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_item(%{"id" => %{"videoId" => video_id}, "snippet" => snippet}) when is_binary(video_id) do
    thumbnails = Map.get(snippet, "thumbnails", %{})

    %{
      youtube_id: video_id,
      title: Map.get(snippet, "title"),
      channel_id: Map.get(snippet, "channelId"),
      channel_title: Map.get(snippet, "channelTitle"),
      published_at: Map.get(snippet, "publishedAt"),
      thumbnail_url: thumbnail_url(thumbnails)
    }
  end

  defp parse_item(_item), do: nil

  defp thumbnail_url(thumbnails) do
    ["high", "medium", "default"]
    |> Enum.find_value(fn key ->
      thumbnails
      |> Map.get(key, %{})
      |> Map.get("url")
    end)
  end

  defp validate_enabled do
    if enabled?(), do: :ok, else: {:error, :youtube_api_key_not_configured}
  end

  defp normalize_query(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:error, :empty_query}
      String.length(query) > @max_query_length -> {:error, :query_too_long}
      true -> {:ok, query}
    end
  end

  defp normalize_query(_query), do: {:error, :empty_query}

  defp normalize_max_results(max_results) when is_binary(max_results) do
    case Integer.parse(max_results) do
      {value, ""} -> normalize_max_results(value)
      _ -> {:error, :invalid_max_results}
    end
  end

  defp normalize_max_results(max_results) when is_integer(max_results) and max_results in 1..25 do
    {:ok, max_results}
  end

  defp normalize_max_results(_max_results), do: {:error, :invalid_max_results}

  defp api_keys do
    case Settings.get!(:youtube_api_key) do
      nil ->
        []

      keys ->
        keys
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp next_api_key do
    api_keys() |> List.first()
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
