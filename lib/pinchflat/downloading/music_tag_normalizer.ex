defmodule Pinchflat.Downloading.MusicTagNormalizer do
  @moduledoc """
  Adds individual artist credits to downloaded audio when yt-dlp supplies them.
  The display artist remains as embedded by yt-dlp.
  """

  require Logger

  def normalize(%{"filepath" => filepath} = metadata) when is_binary(filepath) do
    script = Path.join(:code.priv_dir(:pinchflat), "scripts/normalize_music_tags.py")

    credits =
      Map.take(metadata, ["artist", "artists", "album_artist", "album_artists", "channel", "uploader"])

    case System.cmd("python3", [script, filepath, Jason.encode!(credits)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> Logger.warning("Could not normalize music tags for #{filepath}: #{String.trim(output)}")
    end
  rescue
    error -> Logger.warning("Could not normalize music tags: #{Exception.message(error)}")
  end

  def normalize(_metadata), do: :ok
end
