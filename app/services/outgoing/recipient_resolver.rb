module Outgoing
  class RecipientResolver
    class MissingPostAddressError   < StandardError; end
    class MissingDevOverrideError   < StandardError; end
    class RealListAddressInDevError < StandardError; end

    def self.for(topic)
      if Rails.env.production?
        list = topic.mailing_lists.first
        raise MissingPostAddressError if list.nil? || list.post_address.blank?
        list.post_address
      else
        override = ENV["HACKORUM_DEV_REPLY_TO"]
        raise MissingDevOverrideError if override.blank?
        if MailingList.where("lower(post_address) = lower(?)", override).exists?
          raise RealListAddressInDevError
        end
        override
      end
    end
  end
end
