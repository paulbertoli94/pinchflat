defmodule Pinchflat.Api.Request do
  @moduledoc """
  API request history for external clients.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Pinchflat.Sources.Source

  schema "api_requests" do
    field :youtube_id, :string
    field :request_type, Ecto.Enum, values: [:sync, :import]

    belongs_to :source, Source

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:source_id, :youtube_id, :request_type])
    |> validate_required([:source_id, :youtube_id, :request_type])
    |> validate_format(:youtube_id, ~r/^[A-Za-z0-9_-]{11}$/)
  end
end
