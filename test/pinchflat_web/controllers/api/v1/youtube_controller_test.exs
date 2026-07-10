defmodule PinchflatWeb.Api.V1.YoutubeControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Settings

  @token "test-api-token"

  setup do
    old_token = Application.get_env(:pinchflat, :api_token)
    Application.put_env(:pinchflat, :api_token, @token)

    on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)

    :ok
  end

  describe "GET /api/v1/youtube/search" do
    test "requires bearer auth", %{conn: conn} do
      conn = get(conn, "/api/v1/youtube/search", %{q: "test"})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "returns 409 when YouTube API key is not configured", %{conn: conn} do
      Settings.set(youtube_api_key: nil)

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/youtube/search", %{q: "test"})

      assert %{"error" => %{"code" => "youtube_api_key_not_configured"}} = json_response(conn, 409)
    end

    test "returns 422 when query is empty", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/youtube/search", %{q: " "})

      assert %{"error" => %{"code" => "empty_query"}} = json_response(conn, 422)
    end

    test "searches YouTube through Pinchflat without exposing the API key", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")

      expect(HTTPClientMock, :get, fn url, headers ->
        assert url =~ "https://youtube.googleapis.com/youtube/v3/search?"
        assert url =~ "part=snippet"
        assert url =~ "type=video"
        assert url =~ "maxResults=5"
        assert url =~ "q=daft+punk"
        assert url =~ "key=api-key"
        assert headers == [accept: "application/json"]

        {:ok,
         Jason.encode!(%{
           items: [
             %{
               id: %{videoId: "LdQU46djcAA"},
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

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "youtube_id" => "LdQU46djcAA",
                   "title" => "Song title",
                   "channel_id" => "UC123",
                   "channel_title" => "Artist",
                   "published_at" => "2024-01-01T00:00:00Z",
                   "thumbnail_url" => "https://example.com/thumb.jpg"
                 }
               ]
             } = json_response(conn, 200)

      refute response(conn, 200) =~ "api-key"
    end
  end

  defp api_auth(conn) do
    put_req_header(conn, "authorization", "Bearer #{@token}")
  end
end
