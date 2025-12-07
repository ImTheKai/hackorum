class Topic < ApplicationRecord
  belongs_to :creator, class_name: 'Alias', inverse_of: :topics
  has_many :messages
  has_many :attachments, through: :messages
  has_many :notes, dependent: :destroy
  
  validates :title, presence: true

  def participant_aliases(limit: 5)
    # Get all unique senders from messages, with their message counts
    sender_counts = messages.group(:sender_id)
                            .select('sender_id, COUNT(*) as message_count')
                            .order('message_count DESC')
                            .limit(50) # Get top 50 to work with
                            .index_by(&:sender_id)

    # Get the actual Alias records
    sender_ids = sender_counts.keys
    senders_by_id = Alias.where(id: sender_ids).index_by(&:id)

    # Get first and last message senders
    first_message = messages.order(:created_at).first
    last_message = messages.order(:created_at).last

    first_sender = first_message&.sender
    last_sender = last_message&.sender

    # Build the participants list
    participants = []

    # Always start with the creator (first message sender)
    participants << first_sender if first_sender

    # Add other frequent participants (excluding first and last)
    other_senders = sender_ids - [first_sender&.id, last_sender&.id].compact
    other_participants = other_senders
      .map { |id| senders_by_id[id] }
      .compact
      .sort_by { |s| -sender_counts[s.id].message_count }
      .take(limit - 2) # Reserve space for first and last

    participants.concat(other_participants)

    # Always end with last message sender (if different from first)
    if last_sender && last_sender.id != first_sender&.id
      participants << last_sender
    end

    participants.compact.uniq
  end

  def has_contributor_activity?
    @has_contributor_activity ||= begin
      contributor_alias_ids = Contributor.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: contributor_alias_ids).exists?
    end
  end

  def has_core_team_activity?
    @has_core_team_activity ||= begin
      core_alias_ids = Contributor.core_team.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: core_alias_ids).exists?
    end
  end

  def has_committer_activity?
    @has_committer_activity ||= begin
      committer_alias_ids = Contributor.committers.joins(:aliases).pluck('aliases.id').uniq
      messages.where(sender_id: committer_alias_ids).exists?
    end
  end
end
