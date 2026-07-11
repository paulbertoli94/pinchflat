defmodule Pinchflat.Youtube.MusicBrowse do
  @moduledoc """
  Server-side YouTube Music browse pages for API clients.
  """

  @endpoint "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"
  @client_version "1.20240724.00.00"

  def album(browse_id) do
    with {:ok, browse_id} <- normalize_browse_id(browse_id),
         {:ok, response} <- request(browse_id),
         {:ok, payload} <- Jason.decode(response) do
      {:ok, parse_album(payload, browse_id)}
    end
  end

  def artist(browse_id) do
    with {:ok, browse_id} <- normalize_browse_id(browse_id),
         {:ok, response} <- request(browse_id),
         {:ok, payload} <- Jason.decode(response) do
      {:ok, parse_artist(payload, browse_id)}
    end
  end

  defp request(browse_id) do
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
        browseId: browse_id
      })

    http_client().post(@endpoint, body, headers(), [])
  end

  defp parse_album(payload, browse_id) do
    microformat = get_in(payload, ["microformat", "microformatDataRenderer"]) || %{}
    {title, artist} = album_title_and_artist(Map.get(microformat, "title"))

    %{
      type: "album",
      browse_id: browse_id,
      title: title,
      artist: artist,
      description: Map.get(microformat, "description"),
      thumbnail_url: thumbnail_url(microformat) || thumbnail_url(Map.get(payload, "background", %{})),
      tracks: album_tracks(payload, artist, browse_id)
    }
  end

  defp parse_artist(payload, browse_id) do
    microformat = get_in(payload, ["microformat", "microformatDataRenderer"]) || %{}
    header = get_in(payload, ["header", "musicImmersiveHeaderRenderer"]) || %{}
    sections = music_shelves(payload)

    %{
      type: "artist",
      browse_id: browse_id,
      title: text_from_runs(get_in(header, ["title", "runs"])) || Map.get(microformat, "title"),
      description: Map.get(microformat, "description"),
      thumbnail_url: thumbnail_url(microformat) || thumbnail_url(header),
      top_songs: parse_shelf_items(sections, "Top songs", "song"),
      albums: parse_shelf_items(sections, "Albums", "album"),
      singles: parse_shelf_items(sections, "Singles", "album"),
      videos: parse_shelf_items(sections, "Videos", "video")
    }
  end

  defp album_tracks(payload, artist, album_id) do
    payload
    |> music_shelves()
    |> Enum.flat_map(fn shelf ->
      shelf
      |> shelf_contents()
      |> Enum.map(&parse_track(&1, artist, album_id))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_shelf_items(sections, title, fallback_type) do
    sections
    |> Enum.filter(&(shelf_title(&1) == title))
    |> Enum.flat_map(&shelf_contents/1)
    |> Enum.map(&parse_list_item(&1, fallback_type))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_track(%{"musicResponsiveListItemRenderer" => renderer}, artist, album_id) do
    title_runs = renderer |> flex_column(0) |> runs_from_column()
    youtube_id = video_id(renderer, title_runs)

    if present?(youtube_id) do
      %{
        type: "song",
        youtube_id: youtube_id,
        title: text_from_runs(title_runs),
        artist: artist,
        album_id: album_id,
        track_number: renderer |> get_in(["index", "runs"]) |> text_from_runs() |> parse_int(),
        duration: renderer |> fixed_column(0) |> runs_from_column() |> duration(),
        thumbnail_url: thumbnail_url(renderer)
      }
    end
  end

  defp parse_track(_item, _artist, _album_id), do: nil

  defp parse_list_item(%{"musicResponsiveListItemRenderer" => renderer}, fallback_type) do
    title_runs = renderer |> flex_column(0) |> runs_from_column()
    subtitle_runs = renderer |> flex_column(1) |> runs_from_column()
    all_runs = title_runs ++ subtitle_runs
    browse_id = browse_id(all_runs)
    youtube_id = video_id(renderer, all_runs)

    %{
      type: item_type_for(all_runs, fallback_type, youtube_id),
      youtube_id: youtube_id,
      browse_id: browse_id,
      title: text_from_runs(title_runs),
      artist: text_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST"),
      artist_id: browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST"),
      album: text_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ALBUM"),
      album_id: browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ALBUM"),
      duration: duration(all_runs),
      thumbnail_url: thumbnail_url(renderer)
    }
    |> reject_empty_item()
  end

  defp parse_list_item(%{"musicTwoRowItemRenderer" => renderer}, fallback_type) do
    title_runs = get_in(renderer, ["title", "runs"]) || []
    subtitle_runs = get_in(renderer, ["subtitle", "runs"]) || []
    all_runs = title_runs ++ subtitle_runs

    %{
      type: item_type_for(all_runs, fallback_type, video_id(renderer, all_runs)),
      youtube_id: video_id(renderer, all_runs),
      browse_id: browse_id(all_runs) || get_in(renderer, ["navigationEndpoint", "browseEndpoint", "browseId"]),
      title: text_from_runs(title_runs),
      artist: text_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST"),
      artist_id: browse_id_for_page_type(all_runs, "MUSIC_PAGE_TYPE_ARTIST"),
      thumbnail_url: thumbnail_url(renderer)
    }
    |> reject_empty_item()
  end

  defp parse_list_item(_item, _fallback_type), do: nil

  defp reject_empty_item(%{title: title, youtube_id: youtube_id, browse_id: browse_id} = item) do
    if present?(title) and (present?(youtube_id) or present?(browse_id)), do: item
  end

  defp music_shelves(payload) do
    music_shelves = collect_values(payload, "musicShelfRenderer")
    carousel_shelves = collect_values(payload, "musicCarouselShelfRenderer")

    (music_shelves ++ carousel_shelves)
    |> Enum.reject(&is_nil/1)
  end

  defp collect_values(data, target_key) do
    data
    |> do_collect_values(target_key, [])
    |> Enum.reverse()
  end

  defp do_collect_values(%{} = data, target_key, acc) do
    acc =
      case Map.get(data, target_key) do
        nil -> acc
        value -> [value | acc]
      end

    data
    |> Map.values()
    |> Enum.reduce(acc, &do_collect_values(&1, target_key, &2))
  end

  defp do_collect_values(values, target_key, acc) when is_list(values) do
    Enum.reduce(values, acc, &do_collect_values(&1, target_key, &2))
  end

  defp do_collect_values(_data, _target_key, acc), do: acc

  defp shelf_title(shelf) do
    text_from_runs(get_in(shelf, ["title", "runs"])) ||
      text_from_runs(get_in(shelf, ["header", "musicCarouselShelfBasicHeaderRenderer", "title", "runs"]))
  end

  defp shelf_contents(shelf), do: Map.get(shelf, "contents", [])

  defp flex_column(renderer, index) do
    renderer
    |> Map.get("flexColumns", [])
    |> Enum.at(index, %{})
    |> Map.get("musicResponsiveListItemFlexColumnRenderer", %{})
  end

  defp fixed_column(renderer, index) do
    renderer
    |> Map.get("fixedColumns", [])
    |> Enum.at(index, %{})
    |> Map.get("musicResponsiveListItemFixedColumnRenderer", %{})
  end

  defp runs_from_column(column), do: get_in(column, ["text", "runs"]) || []

  defp text_from_runs(nil), do: nil

  defp text_from_runs(runs) do
    runs
    |> List.wrap()
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
      get_in(renderer, ["navigationEndpoint", "watchEndpoint", "videoId"]) ||
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

  defp item_type_for(runs, fallback_type, youtube_id) when fallback_type in ["song", "video"] do
    if present?(youtube_id) do
      fallback_type
    else
      item_type_for(runs) || fallback_type
    end
  end

  defp item_type_for(runs, fallback_type, _youtube_id) do
    item_type_for(runs) || fallback_type
  end

  defp item_type_for(runs) do
    runs
    |> Enum.find_value(fn run ->
      run
      |> get_in(["navigationEndpoint", "browseEndpoint"])
      |> page_type()
    end)
    |> case do
      "MUSIC_PAGE_TYPE_ALBUM" -> "album"
      "MUSIC_PAGE_TYPE_ARTIST" -> "artist"
      "MUSIC_PAGE_TYPE_PLAYLIST" -> "playlist"
      _page_type -> nil
    end
  end

  defp duration(runs) do
    Enum.find_value(List.wrap(runs), fn run ->
      text = Map.get(run, "text")

      if is_binary(text) and Regex.match?(~r/^\d{1,2}:\d{2}(?::\d{2})?$/, text) do
        text
      end
    end)
  end

  defp thumbnail_url(nil), do: nil

  defp thumbnail_url(renderer) do
    thumbnails =
      get_in(renderer, ["thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"]) ||
        get_in(renderer, ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"]) ||
        get_in(renderer, ["thumbnail", "thumbnails"]) ||
        get_in(renderer, ["thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails"]) ||
        []

    thumbnails
    |> Enum.max_by(&Map.get(&1, "width", 0), fn -> nil end)
    |> case do
      nil -> nil
      thumbnail -> Map.get(thumbnail, "url")
    end
  end

  defp album_title_and_artist(nil), do: {nil, nil}

  defp album_title_and_artist(title) do
    case String.split(title, " - Album by ", parts: 2) do
      [album, artist] -> {album, artist}
      [album] -> {album, nil}
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp normalize_browse_id(browse_id) when is_binary(browse_id) do
    browse_id = String.trim(browse_id)

    if browse_id == "" do
      {:error, :invalid_browse_id}
    else
      {:ok, browse_id}
    end
  end

  defp normalize_browse_id(_browse_id), do: {:error, :invalid_browse_id}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and value != ""

  defp headers do
    [
      accept: "application/json",
      "content-type": "application/json",
      origin: "https://music.youtube.com",
      referer: "https://music.youtube.com/",
      "user-agent": "Mozilla/5.0"
    ]
  end

  defp http_client do
    Application.get_env(:pinchflat, :http_client, Pinchflat.HTTP.HTTPClient)
  end
end
