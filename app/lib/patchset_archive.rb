require "zlib"
require "rubygems/package"

class PatchsetArchive
  def self.build(message:, attachment_number:, host: nil)
    patches = message.attachments
                     .select(&:patch_submission_candidate?)
                     .sort_by(&:file_name)
    return nil if patches.empty?

    topic = message.topic

    tar_gz = StringIO.new
    Zlib::GzipWriter.wrap(tar_gz) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        metadata = build_metadata(topic, message, attachment_number, host: host)
        tar.add_file_simple("hackorum.json", 0644, metadata.bytesize) do |io|
          io.write(metadata)
        end
        patches.each do |patch|
          content = patch.decoded_body
          tar.add_file_simple(patch.file_name, 0644, content.bytesize) do |io|
            io.write(content)
          end
        end
      end
    end

    {
      data: tar_gz.string,
      filename: "topic-#{topic.id}-msg#{attachment_number}-patchset.tar.gz"
    }
  end

  def self.build_metadata(topic, message, attachment_number, host: nil)
    first_message = topic.messages.order(:created_at).first
    first_message_id = first_message&.message_id

    effective_host = host ||
                     Rails.application.config.action_mailer.default_url_options&.dig(:host) ||
                     "localhost"

    {
      attachment_number: attachment_number,
      topic_id: topic.id,
      submission_date: message.created_at.iso8601,
      hackorum_url: Rails.application.routes.url_helpers.topic_url(topic, host: effective_host),
      upstream_url: first_message_id && "https://www.postgresql.org/message-id/flat/#{ERB::Util.url_encode(first_message_id)}"
    }.compact.to_json
  end

  private_class_method :build_metadata
end
