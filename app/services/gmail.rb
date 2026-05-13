module Gmail
  class TransientError < StandardError; end
  class PermanentError < StandardError; end
  class AuthRevokedError < PermanentError; end
  # 403 from Gmail almost always means the OAuth grant is missing the
  # gmail.send scope, not that the token is revoked. Treat it as a permanent
  # send failure but do NOT wipe refresh_token; the user can re-grant the
  # missing scope without redoing the full OAuth dance.
  class ScopeError < PermanentError; end
end
