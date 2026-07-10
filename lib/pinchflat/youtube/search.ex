defmodule Pinchflat.Youtube.Search do
  @moduledoc """
  Server-side YouTube Music search for API clients.
  """

  @max_results 10
  @max_query_length 120
  @endpoint "https://music.youtube.com/youtubei/v1/search?prettyPrint=false"
  @client_version "1.20240724.00.00"

  def enabled?, do: true

  def search(query, opts \\ []) do
    with {:ok, query} <- normalize_query(query),
         {:ok, max_results} <- normalize_max_results(Keyword.get(opts, :max_results, @max_results)),
         {:ok, response} <- request(query, max_results),
         {:ok, payload} <- Jason.decode(response) do
      {:ok, payload |> parse_items() |> Enum.take(max_results)}
    end
  end

  defp request(query, _max_results) do
    body =
      Jason.encode!(%{
        context: %{
          client: %{
            clientName: "WEB_REMIX",
            clientVersion: @client_version,
            hl: "en",
            gl: "US"
          }
        },
        query: query
      })

    http_client().post(@endpoint, body, headers(), [])
  end

  defp parse_items(payload) do
    payload
    |> search_sections()
    |> Enum.flat_map(&parse_section/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&item_key/1)
  end

  defp search_sections(payload) do
    payload
    |> get_in(["contents", "tabbedSearchResultsRenderer", "tabs"])
    |> List.wrap()
    |> Enum.find_value([], fn
      %{"tabRenderer" => %{"selected" => true, "content" => content}} ->
        get_in(content, ["sectionListRenderer", "contents"])

      _tab ->
        nil
    end)
  end

  defp parse_section(%{"musicShelfRenderer" => shelf}) do
    type = shelf |> get_in(["title", "runs"]) |> text_from_runs() |> item_type()

    shelf
    |> Map.get("contents", [])
    |> Enum.map(&parse_music_list_item(&1, type))
  end

  defp parse_section(%{"musicCardShelfRenderer" => card}) do
    case parse_music_card(card) do
      nil -> []
      item -> [item]
    end
  end

  defp parse_section(_section), do: []

  defp parse_music_list_item(%{"musicResponsiveListItemRenderer" => renderer}, type) do
    columns = flex_columns(renderer)
    title_runs = columns |> Enum.at(0, []) |> runs_from_column()
    subtitle_runs = columns |> Enum.at(1, []) |> runs_from_column()
    all_runs = title_runs ++ subtitle_runs

    artist = artist_name(all_runs)
    artist_id = browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST")

    %{
      type: type || infer_type(renderer),
      youtube_id: video_id(renderer, all_runs),
      title: text_from_runs(title_runs),
      artist: artist,
      artist_id: artist_id,
      album: album_name(all_runs),
      album_id: browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ALBUM"),
      channel_id: artist_id,
      channel_title: artist,
      published_at: nil,
      browse_id: browse_id(all_runs),
      duration: duration(all_runs),
      thumbnail_url: thumbnail_url(renderer)
    }
    |> reject_empty_item()
  end

  defp parse_music_list_item(_item, _type), do: nil

  defp parse_music_card(card) do
    title_runs = get_in(card, ["title", "runs"]) || []
    subtitle_runs = get_in(card, ["subtitle", "runs"]) || []
    all_runs = title_runs ++ subtitle_runs

    artist = artist_name(all_runs)
    artist_id = browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST")

    %{
      type: (card |> get_in(["subtitle", "runs"]) |> text_from_runs() |> item_type()) || infer_type(card),
      youtube_id: video_id(card, all_runs),
      title: text_from_runs(title_runs),
      artist: artist,
      artist_id: artist_id,
      album: album_name(all_runs),
      album_id: browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ALBUM"),
      channel_id: artist_id,
      channel_title: artist,
      published_at: nil,
      browse_id: browse_id(all_runs),
      duration: duration(all_runs),
      thumbnail_url: thumbnail_url(card)
    }
    |> reject_empty_item()
  end

  defp reject_empty_item(%{title: title, youtube_id: youtube_id, browse_id: browse_id} = item) do
    if present?(title) and (present?(youtube_id) or present?(browse_id)), do: item
  end

  defp flex_columns(renderer) do
    renderer
    |> Map.get("flexColumns", [])
    |> Enum.map(&Map.get(&1, "musicResponsiveListItemFlexColumnRenderer", %{}))
  end

  defp runs_from_column(column), do: get_in(column, ["text", "runs"]) || []

  defp text_from_runs(nil), do: nil

  defp text_from_runs(runs) do
    runs
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.reject(&(&1 == " • "))
    |> Enum.join("")
    |> String.trim()
    |> blank_to_nil()
  end

  defp video_id(renderer, runs) do
    get_in(renderer, ["playlistItemData", "videoId"]) ||
      get_in(renderer, [
        "overlay",
        "musicItemThumbnailOverlayRenderer",
        "content",
        "musicPlayButtonRenderer",
        "playNavigationEndpoint",
        "watchEndpoint",
        "videoId"
      ]) ||
      Enum.find_value(runs, &get_in(&1, ["navigationEndpoint", "watchEndpoint", "videoId"]))
  end

  defp browse_id(runs) do
    Enum.find_value(runs, &get_in(&1, ["navigationEndpoint", "browseEndpoint", "browseId"]))
  end

  defp browse_id_for_page_type(runs, page_type) do
    Enum.find_value(runs, fn run ->
      browse_endpoint = get_in(run, ["navigationEndpoint", "browseEndpoint"])

      if page_type(browse_endpoint) == page_type do
        Map.get(browse_endpoint, "browseId")
      end
    end)
  end

  defp artist_name(runs), do: text_for_page_type(runs, "MUSIC_PAGE_TYPE_ARTIST")
  defp album_name(runs), do: text_for_page_type(runs, "MUSIC_PAGE_TYPE_ALBUM")

  defp text_for_page_type(runs, page_type) do
    Enum.find_value(runs, fn run ->
      browse_endpoint = get_in(run, ["navigationEndpoint", "browseEndpoint"])

      if page_type(browse_endpoint) == page_type do
        Map.get(run, "text")
      end
    end)
  end

  defp page_type(nil), do: nil

  defp page_type(browse_endpoint) do
    get_in(browse_endpoint, [
      "browseEndpointContextSupportedConfigs",
      "browseEndpointContextMusicConfig",
      "pageType"
    ])
  end

  defp duration(runs) do
    Enum.find_value(runs, fn run ->
      text = Map.get(run, "text")

      if is_binary(text) and Regex.match?(~r/^\d{1,2}:\d{2}(?::\d{2})?$/, text) do
        text
      end
    end)
  end

  defp thumbnail_url(renderer) do
    thumbnails =
      get_in(renderer, ["thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"]) ||
        get_in(renderer, ["thumbnail", "thumbnails"]) ||
        []

    thumbnails
    |> Enum.max_by(&Map.get(&1, "width", 0), fn -> nil end)
    |> case do
      nil -> nil
      thumbnail -> Map.get(thumbnail, "url")
    end
  end

  defp item_type(nil), do: nil

  defp item_type(label) do
    label
    |> String.downcase()
    |> case do
      "songs" -> "song"
      "song" -> "song"
      "videos" -> "video"
      "video" -> "video"
      "albums" -> "album"
      "album" -> "album"
      "artists" -> "artist"
      "artist" -> "artist"
      "playlists" -> "playlist"
      "playlist" -> "playlist"
      _other -> nil
    end
  end

  defp infer_type(renderer) do
    cond do
      present?(get_in(renderer, ["playlistItemData", "videoId"])) -> "song"
      true -> nil
    end
  end

  defp item_key(%{youtube_id: youtube_id}) when is_binary(youtube_id), do: {:youtube_id, youtube_id}
  defp item_key(%{browse_id: browse_id}) when is_binary(browse_id), do: {:browse_id, browse_id}
  defp item_key(item), do: {:title, Map.get(item, :title)}

  defp headers do
    [
      accept: "application/json",
      "content-type": "application/json",
      origin: "https://music.youtube.com",
      referer: "https://music.youtube.com/search",
      "user-agent": "Mozilla/5.0"
    ]
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and value != ""

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

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
