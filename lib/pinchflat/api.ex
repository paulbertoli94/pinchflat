defmodule Pinchflat.Api do
  @moduledoc """
  Helpers for the external REST API.
  """

  import Ecto.Query, warn: false

  alias Pinchflat.Repo
  alias Pinchflat.Media
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.SlowIndexing.SlowIndexingHelpers
  alias Pinchflat.Youtube.OauthClient

  @youtube_id_regex ~r/^[A-Za-z0-9_-]{11}$/
  @max_youtube_ids 500

  def max_youtube_ids, do: @max_youtube_ids

  def get_source(source_id) do
    source =
      case Integer.parse(to_string(source_id)) do
        {id, ""} -> Repo.get(Source, id)
        _ -> Repo.get_by(Source, uuid: source_id)
      end

    case source do
      nil -> {:error, :source_not_found}
      %Source{} = source -> {:ok, source}
    end
  end

  def sync_source(%Source{} = source, youtube_ids) do
    with :ok <- validate_enabled_source(source),
         :ok <- validate_playlist_source(source),
         {:ok, normalized_ids} <- normalize_youtube_ids(youtube_ids) do
      result = SlowIndexingHelpers.kickoff_indexing_task(source, %{force: true})

      case result do
        {:ok, _task} -> {:ok, normalized_ids}
        {:error, :duplicate_job} -> {:ok, normalized_ids}
        {:error, error} -> {:error, {:enqueue_failed, error}}
      end
    end
  end

  def import_to_source(%Source{} = source, youtube_ids) do
    with :ok <- validate_enabled_source(source),
         :ok <- validate_playlist_source(source),
         {:ok, normalized_ids} <- normalize_youtube_ids(youtube_ids),
         {:ok, imported_ids} <- OauthClient.insert_playlist_items(source, normalized_ids),
         {:ok, _synced_ids} <- sync_source(source, imported_ids) do
      {:ok, imported_ids}
    end
  end

  def media_status_for_youtube_id(%Source{} = source, youtube_id) do
    with {:ok, [normalized_id]} <- normalize_youtube_ids([youtube_id]) do
      source
      |> get_media_item_by_youtube_id(normalized_id)
      |> case do
        nil -> {:error, :media_not_found}
        media_item -> {:ok, media_status(media_item)}
      end
    end
  end

  def batch_media_status(%Source{} = source, youtube_ids) do
    with {:ok, normalized_ids} <- normalize_youtube_ids(youtube_ids) do
      media_items_by_id =
        MediaItem
        |> where([mi], mi.source_id == ^source.id and mi.media_id in ^normalized_ids)
        |> preload(:source)
        |> Repo.all()
        |> Map.new(&{&1.media_id, &1})

      items =
        Enum.map(normalized_ids, fn youtube_id ->
          case media_items_by_id[youtube_id] do
            nil -> unknown_status(youtube_id)
            media_item -> media_status(media_item)
          end
        end)

      {:ok, items}
    end
  end

  def normalize_youtube_ids(ids) when is_list(ids) do
    ids = Enum.map(ids, &String.trim(to_string(&1)))

    cond do
      ids == [] ->
        {:error, :empty_youtube_ids}

      length(ids) > @max_youtube_ids ->
        {:error, :too_many_youtube_ids}

      Enum.any?(ids, &(!Regex.match?(@youtube_id_regex, &1))) ->
        {:error, :invalid_youtube_id}

      true ->
        {:ok, Enum.uniq(ids)}
    end
  end

  def normalize_youtube_ids(_ids), do: {:error, :invalid_youtube_ids}

  defp validate_enabled_source(%Source{enabled: true}), do: :ok
  defp validate_enabled_source(%Source{}), do: {:error, :source_disabled}

  defp validate_playlist_source(%Source{collection_type: :playlist}), do: :ok
  defp validate_playlist_source(%Source{}), do: {:error, :source_not_playlist}

  defp get_media_item_by_youtube_id(source, youtube_id) do
    Repo.get_by(MediaItem, source_id: source.id, media_id: youtube_id)
  end

  defp media_status(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, :source)

    %{
      youtube_id: media_item.media_id,
      status: derive_status(media_item),
      media_id: media_item.id,
      media_uuid: media_item.uuid,
      title: media_item.title,
      downloaded_at: media_item.media_downloaded_at,
      filepath: media_item.media_filepath,
      last_error: media_item.last_error
    }
  end

  defp unknown_status(youtube_id) do
    %{
      youtube_id: youtube_id,
      status: "unknown",
      media_id: nil,
      media_uuid: nil,
      title: nil,
      downloaded_at: nil,
      filepath: nil,
      last_error: nil
    }
  end

  defp derive_status(%MediaItem{media_filepath: filepath}) when is_binary(filepath), do: "completed"
  defp derive_status(%MediaItem{prevent_download: true}), do: "prevented"

  defp derive_status(%MediaItem{} = media_item) do
    cond do
      has_download_task?(media_item, [:executing]) -> "downloading"
      has_download_task?(media_item, [:available, :scheduled, :retryable]) -> "queued"
      is_binary(media_item.last_error) -> "failed"
      Media.pending_download?(media_item) -> "pending"
      true -> "discovered"
    end
  end

  defp has_download_task?(media_item, states) do
    media_item
    |> Tasks.list_tasks_for("MediaDownloadWorker", states)
    |> Enum.any?()
  end
end
