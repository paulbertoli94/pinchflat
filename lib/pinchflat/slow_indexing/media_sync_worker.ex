defmodule Pinchflat.SlowIndexing.MediaSyncWorker do
  @moduledoc """
  Verifies requested IDs against a playlist once, then indexes only those videos.
  Imports already confirmed by the YouTube API can skip the membership lookup.
  """

  use Oban.Worker,
    queue: :remote_metadata,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_source", "media_indexing", "show_in_dashboard"]

  import Ecto.Query

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.YtDlp.MediaCollection
  alias Pinchflat.SlowIndexing.MediaIndexingWorker

  def kickoff_with_task(source, youtube_ids, opts \\ []) do
    downloaded_ids =
      MediaItem
      |> where(
        [media],
        media.source_id == ^source.id and media.media_id in ^youtube_ids and not is_nil(media.media_filepath)
      )
      |> select([media], media.media_id)
      |> Repo.all()

    case Enum.sort(youtube_ids -- downloaded_ids) do
      [] ->
        {:ok, :already_downloaded}

      ids ->
        %{source_id: source.id, youtube_ids: ids, verify_membership: Keyword.get(opts, :verify_membership, true)}
        |> new()
        |> Tasks.create_job_with_task(source)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "youtube_ids" => ids} = args}) do
    source = Sources.get_source!(source_id)

    if source.enabled do
      case allowed_ids(source, ids, Map.get(args, "verify_membership", true)) do
        {:ok, allowed_ids} ->
          Enum.reduce_while(allowed_ids, :ok, fn id, _ ->
            case MediaIndexingWorker.kickoff_with_task(source, id) do
              {:ok, _} -> {:cont, :ok}
              {:error, :duplicate_job} -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)

        {:error, output, status} ->
          {:error, {output, status}}

        error ->
          error
      end
    else
      :ok
    end
  rescue
    Ecto.NoResultsError -> {:discard, :source_not_found}
  end

  defp allowed_ids(_source, ids, false), do: {:ok, ids}

  defp allowed_ids(source, ids, true) do
    use_cookies = Sources.use_cookies?(source, :indexing)

    with {:ok, playlist_ids} <-
           MediaCollection.get_media_ids_for_collection(source.original_url, use_cookies: use_cookies) do
      members = MapSet.new(playlist_ids)
      {:ok, Enum.filter(ids, &MapSet.member?(members, &1))}
    end
  end
end
