defmodule PinchflatWeb.Plugs do
  @moduledoc """
  Custom plugs for PinchflatWeb.
  """

  use PinchflatWeb, :router
  alias Pinchflat.Settings

  @doc """
  If the `expose_feed_endpoints` setting is true, this plug does nothing. Otherwise, it calls `basic_auth/2`.
  """
  def maybe_basic_auth(conn, opts) do
    if Application.get_env(:pinchflat, :expose_feed_endpoints) do
      conn
    else
      basic_auth(conn, opts)
    end
  end

  @doc """
  If the `basic_auth_username` and `basic_auth_password` settings are set, this plug calls `Plug.BasicAuth.basic_auth/3`.
  """
  def basic_auth(conn, _opts) do
    username = Application.get_env(:pinchflat, :basic_auth_username)
    password = Application.get_env(:pinchflat, :basic_auth_password)

    if credential_set?(username) && credential_set?(password) do
      Plug.BasicAuth.basic_auth(conn, username: username, password: password, realm: "Pinchflat")
    else
      conn
    end
  end

  @doc """
  Authenticates API requests with `Authorization: Bearer <token>`.
  """
  def api_bearer_auth(conn, _opts) do
    configured_token = Application.get_env(:pinchflat, :api_token)
    provided_token = bearer_token(conn)

    cond do
      !credential_set?(configured_token) ->
        send_json_error(conn, :service_unavailable, "api_token_not_configured", "API token is not configured")

      !credential_set?(provided_token) ->
        send_json_error(conn, :unauthorized, "unauthorized", "Unauthorized")

      secure_token_compare(provided_token, configured_token) ->
        conn

      true ->
        send_json_error(conn, :unauthorized, "unauthorized", "Unauthorized")
    end
  end

  @doc """
  Removes the `x-frame-options` header from the response to allow the page to be embedded in an iframe.
  """
  def allow_iframe_embed(conn, _opts) do
    delete_resp_header(conn, "x-frame-options")
  end

  @doc """
  If the `route_token` query parameter matches the `route_token` setting, this plug does nothing.
  Otherwise, it sends a 401 response.
  """
  def token_protected_route(%{query_params: %{"route_token" => route_token}} = conn, _opts) do
    if Settings.get!(:route_token) == route_token do
      conn
    else
      send_unauthorized(conn)
    end
  end

  def token_protected_route(conn, _opts) do
    send_unauthorized(conn)
  end

  defp credential_set?(credential) do
    credential && credential != ""
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end

  defp secure_token_compare(left, right) do
    left_hash = :crypto.hash(:sha256, left)
    right_hash = :crypto.hash(:sha256, right)

    Plug.Crypto.secure_compare(left_hash, right_hash)
  end

  defp send_unauthorized(conn) do
    conn
    |> send_resp(:unauthorized, "Unauthorized")
    |> halt()
  end

  defp send_json_error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Phoenix.json_library().encode!(%{error: %{code: code, message: message, details: %{}}}))
    |> halt()
  end
end
