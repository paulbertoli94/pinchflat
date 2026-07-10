defmodule PinchflatWeb.Api.V1.SourceSyncControllerTest do
  use PinchflatWeb.ConnCase

  import Ecto.Query
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Repo
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.SlowIndexing.MediaCollectionIndexingWorker

  @token "test-api-token"
  @youtube_id "LdQU46djcAA"

  setup do
    old_token = Application.get_env(:pinchflat, :api_token)
    Application.put_env(:pinchflat, :api_token, @token)

    on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)

    :ok
  end

  describe "auth" do
    test "returns 503 when the API token is not configured", %{conn: conn} do
      Application.put_env(:pinchflat, :api_token, nil)

      conn = post(conn, "/api/v1/sources/1/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "api_token_not_configured"}} = json_response(conn, 503)
    end

    test "returns 401 when the token is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/sources/1/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 when the token is wrong", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> post("/api/v1/sources/1/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "accepts the correct token", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})

      assert %{"status" => "queued"} = json_response(conn, 202)
    end
  end

  describe "POST /api/v1/sources/:id/sync" do
    test "returns 404 when the source does not exist", %{conn: conn} do
      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/999999/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "source_not_found"}} = json_response(conn, 404)
    end

    test "returns 409 when the source is disabled", %{conn: conn} do
      source = playlist_source_fixture(enabled: false)

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "source_disabled"}} = json_response(conn, 409)
    end

    test "returns 409 when the source is not a playlist", %{conn: conn} do
      source = source_fixture(collection_type: "channel")

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})

      assert %{"error" => %{"code" => "source_not_playlist"}} = json_response(conn, 409)
    end

    test "returns 422 when youtube_ids is empty", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: []})

      assert %{"error" => %{"code" => "empty_youtube_ids"}} = json_response(conn, 422)
    end

    test "returns 422 when a YouTube ID is invalid", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: ["https://youtu.be/#{@youtube_id}"]})

      assert %{"error" => %{"code" => "invalid_youtube_id"}} = json_response(conn, 422)
    end

    test "returns 422 when the batch is too large", %{conn: conn} do
      source = playlist_source_fixture()
      ids = Enum.map(1..501, fn index -> String.pad_leading(to_string(index), 11, "A") end)

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: ids})

      assert %{"error" => %{"code" => "too_many_youtube_ids", "details" => %{"max" => 500}}} =
               json_response(conn, 422)
    end

    test "deduplicates YouTube IDs", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id, @youtube_id]})

      assert %{"expected_youtube_ids" => [@youtube_id]} = json_response(conn, 202)
    end

    test "enqueues source indexing with force", %{conn: conn} do
      source = playlist_source_fixture()

      assert [] = all_enqueued(worker: MediaCollectionIndexingWorker)

      conn
      |> api_auth()
      |> post("/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})

      assert [job] = all_enqueued(worker: MediaCollectionIndexingWorker)
      assert job.args == %{"id" => source.id, "force" => true}
    end

    test "repeated sync calls do not leave duplicate indexing jobs", %{conn: conn} do
      source = playlist_source_fixture()
      authed_conn = api_auth(conn)

      post(authed_conn, "/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})
      post(authed_conn, "/api/v1/sources/#{source.id}/sync", %{youtube_ids: [@youtube_id]})

      assert [_job] = all_enqueued(worker: MediaCollectionIndexingWorker)
    end
  end

  describe "GET /api/v1/sources/:id/media/by-youtube-id/:youtube_id" do
    test "returns 404 when the media item is unknown", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/by-youtube-id/#{@youtube_id}")

      assert %{"error" => %{"code" => "media_not_found"}} = json_response(conn, 404)
    end

    test "returns completed status for downloaded media", %{conn: conn} do
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id, media_downloaded_at: now())
      media_item_id = media_item.id
      media_filepath = media_item.media_filepath

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/by-youtube-id/#{@youtube_id}")

      assert %{
               "youtube_id" => @youtube_id,
               "status" => "completed",
               "media_id" => ^media_item_id,
               "filepath" => ^media_filepath
             } = json_response(conn, 200)
    end

    test "does not expose source cookies or sensitive fields", %{conn: conn} do
      source = playlist_source_fixture(cookie_behaviour: "all_operations")
      media_item_fixture(source_id: source.id, media_id: @youtube_id)

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/by-youtube-id/#{@youtube_id}")

      response = json_response(conn, 200)
      refute Map.has_key?(response, "source")
      refute Map.has_key?(response, "cookie_behaviour")
      refute Map.has_key?(response, "authorization")
    end
  end

  describe "POST /api/v1/sources/:id/media/status" do
    test "returns unknown status for unknown media", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/media/status", %{youtube_ids: [@youtube_id]})

      assert %{"items" => [%{"youtube_id" => @youtube_id, "status" => "unknown", "media_id" => nil}]} =
               json_response(conn, 200)
    end

    test "returns completed status", %{conn: conn} do
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id)
      media_item_id = media_item.id

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/media/status", %{youtube_ids: [@youtube_id]})

      assert %{"items" => [%{"status" => "completed", "media_id" => ^media_item_id}]} = json_response(conn, 200)
    end

    test "returns pending status", %{conn: conn} do
      source = playlist_source_fixture()
      media_item_fixture(source_id: source.id, media_id: @youtube_id, media_filepath: nil)

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/media/status", %{youtube_ids: [@youtube_id]})

      assert %{"items" => [%{"status" => "pending"}]} = json_response(conn, 200)
    end

    test "returns queued status", %{conn: conn} do
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id, media_filepath: nil)
      {:ok, _task} = MediaDownloadWorker.kickoff_with_task(media_item)

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/media/status", %{youtube_ids: [@youtube_id]})

      assert %{"items" => [%{"status" => "queued"}]} = json_response(conn, 200)
    end

    test "returns downloading status", %{conn: conn} do
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id, media_filepath: nil)
      {:ok, task} = MediaDownloadWorker.kickoff_with_task(media_item)
      task = Repo.preload(task, :job)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^task.job_id), set: [state: "executing"])

      conn =
        conn
        |> api_auth()
        |> post("/api/v1/sources/#{source.id}/media/status", %{youtube_ids: [@youtube_id]})

      assert %{"items" => [%{"status" => "downloading"}]} = json_response(conn, 200)
    end
  end

  defp api_auth(conn) do
    put_req_header(conn, "authorization", "Bearer #{@token}")
  end

  defp playlist_source_fixture(attrs \\ []) do
    attrs
    |> Enum.into(%{collection_type: "playlist", original_url: "https://www.youtube.com/playlist?list=PL123"})
    |> source_fixture()
  end
end
