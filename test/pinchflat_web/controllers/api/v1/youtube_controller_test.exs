defmodule PinchflatWeb.Api.V1.YoutubeControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  @token "test-api-token"
  @youtube_id "LdQU46djcAA"

  setup do
    old_token = Application.get_env(:pinchflat, :api_token)
    Application.put_env(:pinchflat, :api_token, @token)

    on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)

    :ok
  end

  describe "GET /api/v1/youtube/search" do
    test "requires bearer auth", %{conn: conn} do
      source = playlist_source_fixture()
      conn = get(conn, "/api/v1/sources/#{source.id}/youtube/search", %{q: "test"})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "returns 409 when YouTube API key is not configured", %{conn: conn} do
      Settings.set(youtube_api_key: nil)
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "test"})

      assert %{"error" => %{"code" => "youtube_api_key_not_configured"}} = json_response(conn, 409)
    end

    test "returns 422 when query is empty", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: " "})

      assert %{"error" => %{"code" => "empty_query"}} = json_response(conn, 422)
    end

    test "searches YouTube through Pinchflat without exposing the API key", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "youtube_id" => @youtube_id,
                   "title" => "Song title",
                   "channel_id" => "UC123",
                   "channel_title" => "Artist",
                   "published_at" => "2024-01-01T00:00:00Z",
                   "thumbnail_url" => "https://example.com/thumb.jpg",
                   "pinchflat_status" => %{"status" => "unknown"}
                 }
               ]
             } = json_response(conn, 200)

      refute response(conn, 200) =~ "api-key"
    end

    test "includes unknown Pinchflat status when source_id is provided and media is not known", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "youtube_id" => @youtube_id,
                   "pinchflat_status" => %{
                     "source_id" => source_id,
                     "status" => "unknown",
                     "in_source" => false,
                     "already_downloaded" => false,
                     "media_id" => nil
                   }
                 }
               ]
             } = json_response(conn, 200)

      assert source_id == source.id
    end

    test "includes completed Pinchflat status when media is already downloaded", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id)

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "pinchflat_status" => %{
                     "status" => "completed",
                     "in_source" => true,
                     "already_downloaded" => true,
                     "media_id" => media_item_id
                   }
                 }
               ]
             } = json_response(conn, 200)

      assert media_item_id == media_item.id
    end

    test "returns 404 when source_id is unknown", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/999999/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{"error" => %{"code" => "source_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/sources/:id/media/history" do
    test "returns recent media for a source", %{conn: conn} do
      source = playlist_source_fixture()

      older =
        media_item_fixture(source_id: source.id, media_id: "older000000", media_downloaded_at: ~U[2024-01-01 00:00:00Z])

      newer =
        media_item_fixture(source_id: source.id, media_id: "newer000000", media_downloaded_at: ~U[2024-01-02 00:00:00Z])

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/history", %{limit: 2})

      assert %{"items" => [%{"media_id" => newer_id}, %{"media_id" => older_id}]} = json_response(conn, 200)
      assert newer_id == newer.id
      assert older_id == older.id
    end

    test "returns 422 for invalid history limit", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/history", %{limit: 101})

      assert %{"error" => %{"code" => "invalid_limit"}} = json_response(conn, 422)
    end
  end

  defp api_auth(conn) do
    put_req_header(conn, "authorization", "Bearer #{@token}")
  end

  defp expect_search_request do
    expect(HTTPClientMock, :get, fn url, headers ->
      assert url =~ "https://youtube.googleapis.com/youtube/v3/search?"
      assert url =~ "part=snippet"
      assert url =~ "type=video"
      assert url =~ "videoCategoryId=10"
      assert url =~ "videoDuration=medium"
      assert url =~ "maxResults=5"
      assert url =~ "q=daft+punk"
      assert url =~ "key=api-key"
      assert headers == [accept: "application/json"]

      {:ok,
       Jason.encode!(%{
         items: [
           %{
             id: %{videoId: @youtube_id},
             snippet: %{
               title: "Song title",
               channelId: "UC123",
               channelTitle: "Artist",
               publishedAt: "2024-01-01T00:00:00Z",
               thumbnails: %{medium: %{url: "https://example.com/thumb.jpg"}}
             }
           }
         ]
       })}
    end)
  end

  defp playlist_source_fixture(attrs \\ []) do
    attrs
    |> Enum.into(%{collection_type: "playlist", original_url: "https://www.youtube.com/playlist?list=PL123"})
    |> source_fixture()
  end
end
