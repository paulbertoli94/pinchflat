defmodule Pinchflat.SlowIndexing.MediaIndexingWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.SlowIndexing.MediaIndexingWorker
  alias Pinchflat.Downloading.MediaDownloadWorker
  alias Pinchflat.Media.MediaItem

  @youtube_id "abcdefghijk"

  test "indexes and queues a requested video without listing its playlist" do
    source = source_fixture(collection_type: :playlist)

    expect(YtDlpRunnerMock, :run, fn url, :get_media_attributes, _, _, opts ->
      assert url == "https://www.youtube.com/watch?v=#{@youtube_id}"
      assert Keyword.has_key?(opts, :use_cookies)

      {:ok,
       Jason.encode!(%{
         id: @youtube_id,
         title: "New song",
         original_url: url,
         live_status: "not_live",
         duration: 180,
         upload_date: "20261101",
         filename: "/tmp/new.mp3"
       })}
    end)

    assert :ok = perform_job(MediaIndexingWorker, %{source_id: source.id, youtube_id: @youtube_id})
    media = Repo.get_by!(MediaItem, source_id: source.id, media_id: @youtube_id)
    assert_enqueued(worker: MediaDownloadWorker, args: %{id: media.id})
  end

  test "does not extract metadata or download an already downloaded video" do
    source = source_fixture()
    media_item_fixture(source_id: source.id, media_id: @youtube_id, media_downloaded_at: now())

    assert :ok = perform_job(MediaIndexingWorker, %{source_id: source.id, youtube_id: @youtube_id})
    assert [] = all_enqueued(worker: MediaDownloadWorker)
  end

  test "does not process a disabled source" do
    source = source_fixture(enabled: false)
    assert :ok = perform_job(MediaIndexingWorker, %{source_id: source.id, youtube_id: @youtube_id})
    refute Repo.get_by(MediaItem, source_id: source.id, media_id: @youtube_id)
  end

  test "metadata failures remain retryable rather than triggering a playlist scan" do
    source = source_fixture()
    expect(YtDlpRunnerMock, :run, fn _, :get_media_attributes, _, _, _ -> {:error, "network error", 1} end)

    assert {:error, {"network error", 1}} =
             MediaIndexingWorker.perform(%Oban.Job{args: %{"source_id" => source.id, "youtube_id" => @youtube_id}})

    refute Repo.get_by(MediaItem, source_id: source.id, media_id: @youtube_id)
  end

  test "a known pending video queues its download without extracting metadata" do
    source = source_fixture()
    media = media_item_fixture(source_id: source.id, media_id: @youtube_id, media_filepath: nil)
    assert {:ok, _} = MediaIndexingWorker.kickoff_with_task(source, @youtube_id)
    assert_enqueued(worker: MediaDownloadWorker, args: %{id: media.id})
    assert [] = all_enqueued(worker: MediaIndexingWorker)
  end
end
