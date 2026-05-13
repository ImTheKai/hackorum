require "securerandom"
require "mail"
require "set"

module Outgoing
  class MessageBuilder
    Result = Struct.new(:encoded, :message_id, :subject, :recipient,
                        keyword_init: true)
    DEFAULT_DOMAIN = "hackorum.dev"

    def self.build(draft)
      recipient = RecipientResolver.for(draft.topic)
      domain    = ENV.fetch("HACKORUM_OUTGOING_DOMAIN", DEFAULT_DOMAIN)
      msg_id    = "<#{SecureRandom.uuid}@#{domain}>"

      from_addr = draft.sender_alias
      mail = Mail.new do
        from       "#{from_addr.name} <#{from_addr.email}>"
        to         recipient
        subject    draft.subject
        message_id msg_id
        body       draft.body
      end
      mail.content_type "text/plain; charset=UTF-8"
      mail.in_reply_to = draft.reply_to_message.message_id.to_s.gsub(/[<>]/, "")
      mail.references  = build_references(draft.reply_to_message)

      Result.new(encoded: mail.encoded, message_id: msg_id,
                 subject: draft.subject, recipient: recipient)
    end

    def self.build_references(parent)
      chain = []
      seen  = Set.new
      cur   = parent
      while cur && seen.add?(cur.id)
        if cur.message_id.present?
          chain.unshift(cur.message_id.to_s.gsub(/[<>]/, ""))
        end
        cur = cur.reply_to
      end
      chain
    end
  end
end
