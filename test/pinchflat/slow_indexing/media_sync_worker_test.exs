defmodule Pinchflat.SlowIndexing.MediaSyncWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.SlowIndexing.MediaSyncWorker
  alias Pinchflat.SlowIndexing.MediaIndexingWorker

  test "sync verifies membership once and only indexes requested playlist members" do
    source = source_fixture(collection_type: :playlist)

    expect(YtDlpRunnerMock, :run, fn _, :get_media_ids_for_collection, _, _, _ ->
      {:ok, "abcdefghijk\nother-video\n"}
    end)

    assert :ok = perform_job(MediaSyncWorker, %{source_id: source.id, youtube_ids: ["abcdefghijk", "not-in-list"]})
    assert [job] = all_enqueued(worker: MediaIndexingWorker)
    assert job.args == %{"source_id" => source.id, "youtube_id" => "abcdefghijk"}
  end

  test "confirmed imports queue only imported videos without listing the playlist" do
    source = source_fixture(collection_type: :playlist)

    assert :ok =
             perform_job(MediaSyncWorker, %{
               source_id: source.id,
               youtube_ids: ["abcdefghijk"],
               verify_membership: false
             })

    assert [job] = all_enqueued(worker: MediaIndexingWorker)
    assert job.args["youtube_id"] == "abcdefghijk"
  end

  test "failed membership lookups do not enqueue unchecked videos" do
    source = source_fixture(collection_type: :playlist)
    expect(YtDlpRunnerMock, :run, fn _, :get_media_ids_for_collection, _, _, _ -> {:error, "network error", 1} end)

    assert {:error, {"network error", 1}} =
             MediaSyncWorker.perform(%Oban.Job{args: %{"source_id" => source.id, "youtube_ids" => ["abcdefghijk"]}})

    assert [] = all_enqueued(worker: MediaIndexingWorker)
  end
end
