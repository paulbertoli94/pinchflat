defmodule Pinchflat.Repo.Migrations.AddGoogleOauthToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :google_oauth_client_id, :string
      add :google_oauth_client_secret, :string
      add :google_oauth_refresh_token, :string
      add :google_oauth_connected_at, :utc_datetime
    end
  end
end
