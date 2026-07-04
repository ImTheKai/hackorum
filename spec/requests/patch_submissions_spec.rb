require "rails_helper"

RSpec.describe "Patch submissions API", type: :request do
  def make_submission(paths:, at:)
    msg = create(:message, created_at: at)
    PatchSubmissionFile.insert_all(paths.map { |p| { message_id: msg.id, path: p } })
    msg
  end

  it "lists messages with paths, oldest first, and paginates by cursor" do
    t0 = Time.utc(2009, 1, 1)
    m1 = make_submission(paths: [ "src/a.c" ], at: t0)
    m2 = make_submission(paths: [ "src/b.c", "src/c.c" ], at: t0 + 1.day)
    m3 = make_submission(paths: [ "src/d.c" ], at: t0 + 2.days)
    create(:message, created_at: t0) # no paths -> excluded

    get "/patch_submissions.json", params: { per: 2 }
    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    ids = body["patch_submissions"].map { |s| s["id"] }
    expect(ids).to eq([ m1.id, m2.id ])
    expect(body["patch_submissions"][1]["paths"]).to match_array([ "src/b.c", "src/c.c" ])
    expect(body["patch_submissions"][0]["topic_id"]).to eq(m1.topic_id)
    expect(body["next_cursor"]).to be_present

    get "/patch_submissions.json", params: { per: 2, since: body["next_cursor"] }
    body2 = JSON.parse(response.body)
    expect(body2["patch_submissions"].map { |s| s["id"] }).to eq([ m3.id ])

    get "/patch_submissions.json", params: { per: 2, since: body2["next_cursor"] }
    expect(JSON.parse(response.body)["patch_submissions"]).to eq([])
  end

  it "pages through shared timestamps without skipping or duplicating" do
    t = Time.utc(2009, 1, 1, 12, 0, 0.123456)
    m1 = make_submission(paths: [ "src/a.c" ], at: t)
    m2 = make_submission(paths: [ "src/b.c" ], at: t)
    m3 = make_submission(paths: [ "src/c.c" ], at: t + 0.000001)

    seen = []
    cursor = nil
    4.times do
      params = { per: 1 }
      params[:since] = cursor if cursor
      get "/patch_submissions.json", params: params
      page = JSON.parse(response.body)
      break if page["patch_submissions"].empty?
      seen.concat(page["patch_submissions"].map { |s| s["id"] })
      cursor = page["next_cursor"]
    end
    expect(seen).to eq([ m1.id, m2.id, m3.id ])
  end

  it "rejects unparseable since and until" do
    get "/patch_submissions.json", params: { since: "25:99:99" }
    expect(response).to have_http_status(:bad_request)

    get "/patch_submissions.json", params: { until: "not-a-date" }
    expect(response).to have_http_status(:bad_request)
  end

  it "honors a plain ISO since and an until bound" do
    t0 = Time.utc(2009, 1, 1)
    make_submission(paths: [ "src/a.c" ], at: t0)
    mid = make_submission(paths: [ "src/b.c" ], at: t0 + 10.days)
    make_submission(paths: [ "src/c.c" ], at: t0 + 20.days)

    get "/patch_submissions.json",
        params: { since: (t0 + 5.days).iso8601, until: (t0 + 15.days).iso8601 }
    ids = JSON.parse(response.body)["patch_submissions"].map { |s| s["id"] }
    expect(ids).to eq([ mid.id ])
  end
end
