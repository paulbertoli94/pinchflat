defmodule Pinchflat.HTTP.HTTPClient do
  @moduledoc """
  This module provides a simple interface for making HTTP requests.

  Made to be easily swappable with other HTTP clients. If you need more complexity
  or security, check out HTTPoison or Mint.
  """

  alias Pinchflat.HTTP.HTTPBehaviour

  @behaviour HTTPBehaviour

  @doc """
  Makes a GET request to the given URL and returns the response.

  NOTE: I can't really test this with Mox and I can't think of a way to test this
  that isn't ultimately redundant. I'm just going to leave it untested for now and
  focus more on testing the consumers of this module.

  Returns {:ok, String.t()} | {:error, String.t()}
  """
  @impl HTTPBehaviour
  def get(url, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)

    case :httpc.request(:get, {url, headers}, [], opts) do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, _body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{reason}"}
    end
  end

  @impl HTTPBehaviour
  def post(url, body, headers \\ [], opts \\ []) do
    headers = parse_headers(headers)
    content_type = headers |> List.keyfind(~c"content-type", 0, {~c"content-type", ~c"application/json"}) |> elem(1)

    case :httpc.request(:post, {url, headers, content_type, body}, [], opts) do
      {:ok, {{_version, status_code, _reason_phrase}, _headers, body}} when status_code in 200..299 ->
        {:ok, to_string(body)}

      {:ok, {{_version, status_code, reason_phrase}, _headers, body}} ->
        {:error, "HTTP request failed with status code #{status_code}: #{reason_phrase}: #{to_string(body)}"}

      {:error, reason} ->
        {:error, "HTTP request failed: #{reason}"}
    end
  end

  defp parse_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end
end
