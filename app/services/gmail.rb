module Gmail
  class TransientError < StandardError; end
  class PermanentError < StandardError; end
  class AuthRevokedError < PermanentError; end
end
