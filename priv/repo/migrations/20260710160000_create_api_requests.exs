defmodule Pinchflat.Repo.Migrations.CreateApiRequests do
  use Ecto.Migration

  def change do
    create table(:api_requests) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :youtube_id, :string, null: false
      add :request_type, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:api_requests, [:source_id, :inserted_at])
    create index(:api_requests, [:source_id, :youtube_id])
  end
end
