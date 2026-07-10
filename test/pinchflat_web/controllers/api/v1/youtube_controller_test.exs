defmodule PinchflatWeb.Api.V1.YoutubeControllerTest do
  use PinchflatWeb.ConnCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Settings

  @token "test-api-token"
  @youtube_id "LdQU46djcAA"

  setup do
    old_token = Application.get_env(:pinchflat, :api_token)
    Application.put_env(:pinchflat, :api_token, @token)

    on_exit(fn -> Application.put_env(:pinchflat, :api_token, old_token) end)

    :ok
  end

  describe "GET /api/v1/youtube/search" do
    test "requires bearer auth", %{conn: conn} do
      source = playlist_source_fixture()
      conn = get(conn, "/api/v1/sources/#{source.id}/youtube/search", %{q: "test"})

      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "searches without requiring a YouTube API key", %{conn: conn} do
      Settings.set(youtube_api_key: nil)
      source = playlist_source_fixture()

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "test"})

      assert %{"items" => [%{"youtube_id" => @youtube_id}]} = json_response(conn, 200)
    end

    test "returns 422 when query is empty", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: " "})

      assert %{"error" => %{"code" => "empty_query"}} = json_response(conn, 422)
    end

    test "searches YouTube through Pinchflat without exposing the API key", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "youtube_id" => @youtube_id,
                   "title" => "Song title",
                   "type" => "song",
                   "artist" => "Artist",
                   "artist_id" => "UC123",
                   "album" => "Album",
                   "album_id" => "MPRE123",
                   "duration" => "3:45",
                   "channel_id" => "UC123",
                   "channel_title" => "Artist",
                   "published_at" => nil,
                   "thumbnail_url" => "https://example.com/thumb.jpg",
                   "pinchflat_status" => %{"status" => "unknown"}
                 }
               ]
             } = json_response(conn, 200)

      refute response(conn, 200) =~ "api-key"
    end

    test "includes unknown Pinchflat status when source_id is provided and media is not known", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "youtube_id" => @youtube_id,
                   "pinchflat_status" => %{
                     "source_id" => source_id,
                     "status" => "unknown",
                     "in_source" => false,
                     "already_downloaded" => false,
                     "media_id" => nil
                   }
                 }
               ]
             } = json_response(conn, 200)

      assert source_id == source.id
    end

    test "includes completed Pinchflat status when media is already downloaded", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id)

      expect_search_request()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{
               "items" => [
                 %{
                   "pinchflat_status" => %{
                     "status" => "completed",
                     "in_source" => true,
                     "already_downloaded" => true,
                     "media_id" => media_item_id
                   }
                 }
               ]
             } = json_response(conn, 200)

      assert media_item_id == media_item.id
    end

    test "returns 404 when source_id is unknown", %{conn: conn} do
      Settings.set(youtube_api_key: "api-key")

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/999999/youtube/search", %{q: "daft punk", max_results: 5})

      assert %{"error" => %{"code" => "source_not_found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/sources/:id/youtube/music/albums/:browse_id" do
    test "returns album details with track statuses", %{conn: conn} do
      source = playlist_source_fixture()
      media_item = media_item_fixture(source_id: source.id, media_id: @youtube_id)

      expect_browse_request("MPRE123", album_payload())

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/music/albums/MPRE123")

      assert %{
               "album" => %{
                 "type" => "album",
                 "browse_id" => "MPRE123",
                 "title" => "Album",
                 "artist" => "Artist",
                 "tracks" => [
                   %{
                     "type" => "song",
                     "youtube_id" => @youtube_id,
                     "title" => "Song title",
                     "duration" => "3:45",
                     "track_number" => 1,
                     "pinchflat_status" => %{"media_id" => media_item_id, "status" => "completed"}
                   }
                 ]
               }
             } = json_response(conn, 200)

      assert media_item_id == media_item.id
    end
  end

  describe "GET /api/v1/sources/:id/youtube/music/artists/:browse_id" do
    test "returns artist sections with statuses for playable items", %{conn: conn} do
      source = playlist_source_fixture()

      expect_browse_request("UC123", artist_payload())

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/youtube/music/artists/UC123")

      assert %{
               "artist" => %{
                 "type" => "artist",
                 "browse_id" => "UC123",
                 "title" => "Artist",
                 "top_songs" => [
                   %{
                     "youtube_id" => @youtube_id,
                     "title" => "Song title",
                     "pinchflat_status" => %{"status" => "unknown"}
                   }
                 ],
                 "albums" => [
                   %{
                     "type" => "album",
                     "browse_id" => "MPRE123",
                     "title" => "Album"
                   }
                 ]
               }
             } = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/sources/:id/media/history" do
    test "returns recent media for a source", %{conn: conn} do
      source = playlist_source_fixture()

      older =
        media_item_fixture(source_id: source.id, media_id: "older000000", media_downloaded_at: ~U[2024-01-01 00:00:00Z])

      newer =
        media_item_fixture(source_id: source.id, media_id: "newer000000", media_downloaded_at: ~U[2024-01-02 00:00:00Z])

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/history", %{limit: 2})

      assert %{"items" => [%{"media_id" => newer_id}, %{"media_id" => older_id}]} = json_response(conn, 200)
      assert newer_id == newer.id
      assert older_id == older.id
    end

    test "includes API requests that are not known media yet", %{conn: conn} do
      source = playlist_source_fixture()
      requested_youtube_id = "Req00000001"
      authed_conn = api_auth(conn)

      post(authed_conn, "/api/v1/sources/#{source.id}/sync", %{youtube_ids: [requested_youtube_id]})

      conn =
        authed_conn
        |> get("/api/v1/sources/#{source.id}/media/history", %{limit: 10})

      assert %{
               "items" => [
                 %{
                   "history_type" => "request",
                   "request_type" => "sync",
                   "youtube_id" => ^requested_youtube_id,
                   "status" => "requested",
                   "media_id" => nil,
                   "requested_at" => requested_at
                 }
               ]
             } = json_response(conn, 200)

      assert is_binary(requested_at)
    end

    test "returns 422 for invalid history limit", %{conn: conn} do
      source = playlist_source_fixture()

      conn =
        conn
        |> api_auth()
        |> get("/api/v1/sources/#{source.id}/media/history", %{limit: 101})

      assert %{"error" => %{"code" => "invalid_limit"}} = json_response(conn, 422)
    end
  end

  defp api_auth(conn) do
    put_req_header(conn, "authorization", "Bearer #{@token}")
  end

  defp expect_search_request do
    expect(HTTPClientMock, :post, fn url, body, headers, _opts ->
      assert url == "https://music.youtube.com/youtubei/v1/search?prettyPrint=false"
      assert %{query: query, context: %{client: %{clientName: "WEB_REMIX"}}} = Jason.decode!(body, keys: :atoms)
      assert query in ["daft punk", "test"]
      assert headers[:accept] == "application/json"
      assert headers[:"content-type"] == "application/json"
      assert headers[:origin] == "https://music.youtube.com"

      {:ok,
       Jason.encode!(%{
         contents: %{
           tabbedSearchResultsRenderer: %{
             tabs: [
               %{
                 tabRenderer: %{
                   selected: true,
                   content: %{
                     sectionListRenderer: %{
                       contents: [
                         %{
                           musicShelfRenderer: %{
                             title: %{runs: [%{text: "Songs"}]},
                             contents: [
                               youtube_music_song()
                             ]
                           }
                         }
                       ]
                     }
                   }
                 }
               }
             ]
           }
         }
       })}
    end)
  end

  defp expect_browse_request(browse_id, payload) do
    expect(HTTPClientMock, :post, fn url, body, headers, _opts ->
      assert url == "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"
      assert %{browseId: ^browse_id, context: %{client: %{clientName: "WEB_REMIX"}}} = Jason.decode!(body, keys: :atoms)
      assert headers[:accept] == "application/json"
      assert headers[:"content-type"] == "application/json"
      assert headers[:origin] == "https://music.youtube.com"

      {:ok, Jason.encode!(payload)}
    end)
  end

  defp youtube_music_song do
    %{
      musicResponsiveListItemRenderer: %{
        thumbnail: %{
          musicThumbnailRenderer: %{
            thumbnail: %{
              thumbnails: [
                %{url: "https://example.com/small.jpg", width: 60},
                %{url: "https://example.com/thumb.jpg", width: 120}
              ]
            }
          }
        },
        playlistItemData: %{videoId: @youtube_id},
        flexColumns: [
          %{
            musicResponsiveListItemFlexColumnRenderer: %{
              text: %{
                runs: [
                  %{
                    text: "Song title",
                    navigationEndpoint: %{watchEndpoint: %{videoId: @youtube_id}}
                  }
                ]
              }
            }
          },
          %{
            musicResponsiveListItemFlexColumnRenderer: %{
              text: %{
                runs: [
                  %{
                    text: "Artist",
                    navigationEndpoint: %{
                      browseEndpoint: %{
                        browseId: "UC123",
                        browseEndpointContextSupportedConfigs: %{
                          browseEndpointContextMusicConfig: %{pageType: "MUSIC_PAGE_TYPE_ARTIST"}
                        }
                      }
                    }
                  },
                  %{text: " • "},
                  %{
                    text: "Album",
                    navigationEndpoint: %{
                      browseEndpoint: %{
                        browseId: "MPRE123",
                        browseEndpointContextSupportedConfigs: %{
                          browseEndpointContextMusicConfig: %{pageType: "MUSIC_PAGE_TYPE_ALBUM"}
                        }
                      }
                    }
                  },
                  %{text: " • "},
                  %{text: "3:45"}
                ]
              }
            }
          }
        ]
      }
    }
  end

  defp album_payload do
    %{
      microformat: %{
        microformatDataRenderer: %{
          title: "Album - Album by Artist",
          description: "Album description",
          thumbnail: %{thumbnails: [%{url: "https://example.com/album.jpg", width: 544}]}
        }
      },
      contents: %{
        twoColumnBrowseResultsRenderer: %{
          secondaryContents: %{
            sectionListRenderer: %{
              contents: [
                %{
                  musicShelfRenderer: %{
                    contents: [
                      album_track()
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  end

  defp artist_payload do
    %{
      header: %{
        musicImmersiveHeaderRenderer: %{
          title: %{runs: [%{text: "Artist"}]}
        }
      },
      microformat: %{
        microformatDataRenderer: %{
          title: "Artist",
          description: "Artist description",
          thumbnail: %{thumbnails: [%{url: "https://example.com/artist.jpg", width: 544}]}
        }
      },
      contents: %{
        singleColumnBrowseResultsRenderer: %{
          tabs: [
            %{
              tabRenderer: %{
                selected: true,
                content: %{
                  sectionListRenderer: %{
                    contents: [
                      %{
                        musicShelfRenderer: %{title: %{runs: [%{text: "Top songs"}]}, contents: [youtube_music_song()]}
                      },
                      %{musicShelfRenderer: %{title: %{runs: [%{text: "Albums"}]}, contents: [artist_album()]}}
                    ]
                  }
                }
              }
            }
          ]
        }
      }
    }
  end

  defp album_track do
    %{
      musicResponsiveListItemRenderer: %{
        playlistItemData: %{videoId: @youtube_id},
        index: %{runs: [%{text: "1"}]},
        fixedColumns: [
          %{
            musicResponsiveListItemFixedColumnRenderer: %{
              text: %{runs: [%{text: "3:45"}]}
            }
          }
        ],
        flexColumns: [
          %{
            musicResponsiveListItemFlexColumnRenderer: %{
              text: %{runs: [%{text: "Song title", navigationEndpoint: %{watchEndpoint: %{videoId: @youtube_id}}}]}
            }
          }
        ]
      }
    }
  end

  defp artist_album do
    %{
      musicTwoRowItemRenderer: %{
        title: %{runs: [%{text: "Album"}]},
        navigationEndpoint: %{browseEndpoint: %{browseId: "MPRE123"}},
        thumbnailRenderer: %{
          musicThumbnailRenderer: %{thumbnail: %{thumbnails: [%{url: "https://example.com/album.jpg", width: 120}]}}
        }
      }
    }
  end

  defp playlist_source_fixture(attrs \\ []) do
    attrs
    |> Enum.into(%{collection_type: "playlist", original_url: "https://www.youtube.com/playlist?list=PL123"})
    |> source_fixture()
  end
end
