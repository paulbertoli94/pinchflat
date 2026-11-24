defmodule Pinchflat.SlowIndexing.MediaIndexingWorker do
  @moduledoc """
  Indexes a requested video without scanning or restarting its playlist.
  """

  use Oban.Worker,
    queue: :remote_metadata,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_source", "media_indexing", "show_in_dashboard"]

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.DownloadingHelpers
  alias Pinchflat.Downloading.DownloadOptionBuilder
  alias Pinchflat.YtDlp.Media, as: YtDlpMedia

  def kickoff_with_task(source, youtube_id) do
    case Repo.get_by(MediaItem, source_id: source.id, media_id: youtube_id) do
      nil ->
        %{source_id: source.id, youtube_id: youtube_id}
        |> new()
        |> Tasks.create_job_with_task(source)

      media_item ->
        enqueue_download(media_item)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "youtube_id" => youtube_id}}) do
    source = Sources.get_source!(source_id)

    if source.enabled do
      case Repo.get_by(MediaItem, source_id: source.id, media_id: youtube_id) do
        nil -> index_new_media(source, youtube_id)
        media_item -> enqueue_download(media_item)
      end
      |> case do
        {:ok, _} -> :ok
        {:error, :duplicate_job} -> :ok
        {:error, output, status} -> {:error, {output, status}}
        error -> error
      end
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> {:discard, :source_not_found}
  end

  defp index_new_media(source, youtube_id) do
    source = Repo.preload(source, :media_profile)

    command_opts =
      [output: DownloadOptionBuilder.build_output_path_for(source)] ++
        DownloadOptionBuilder.build_quality_options_for(source)

    url = "https://www.youtube.com/watch?v=#{youtube_id}"
    use_cookies = Sources.use_cookies?(source, :indexing)

    with {:ok, attrs} <- YtDlpMedia.get_media_attributes(url, command_opts, use_cookies: use_cookies),
         {:ok, media_item} <- Media.create_media_item_from_backend_attrs(source, attrs) do
      enqueue_download(media_item)
    end
  end

  defp enqueue_download(media_item) do
    case DownloadingHelpers.kickoff_download_if_pending(media_item) do
      {:error, :should_not_download} -> {:ok, :not_pending}
      result -> result
    end
  end
end
