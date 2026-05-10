require "net/http"
require "json"

module OAuth
  class TokenRefresher
    TOKEN_URL = "https://oauth2.googleapis.com/token"

    def self.call(identity)
      return if fresh?(identity)

      response = Net::HTTP.post_form(URI(TOKEN_URL), {
        client_id:     ENV.fetch("GOOGLE_CLIENT_ID"),
        client_secret: ENV.fetch("GOOGLE_CLIENT_SECRET"),
        refresh_token: identity.refresh_token,
        grant_type:    "refresh_token"
      })

      case response.code.to_i
      when 200
        body = JSON.parse(response.body)
        raise Gmail::TransientError, "200 OK with no access_token in response" if body["access_token"].blank?
        identity.update!(
          access_token:            body["access_token"],
          access_token_expires_at: body["expires_in"].to_i.seconds.from_now
        )
      when 400..499
        identity.update!(
          refresh_token: nil,
          access_token: nil,
          access_token_expires_at: nil,
          send_revoked_at: Time.current,
          last_send_error: "Authorization revoked: #{response.body}"
        )
        raise Gmail::AuthRevokedError, response.body
      else
        raise Gmail::TransientError, response.body
      end
    end

    def self.fresh?(identity)
      identity.access_token.present? &&
        identity.access_token_expires_at &&
        identity.access_token_expires_at > 1.minute.from_now
    end
  end
end
