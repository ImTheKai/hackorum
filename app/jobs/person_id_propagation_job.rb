class PersonIdPropagationJob < ApplicationJob
  queue_as :default

  def perform(alias_id, new_person_id)
    # Update topics where this alias is the creator
    Topic.where(creator_id: alias_id)
         .where.not(creator_person_id: new_person_id)
         .update_all(creator_person_id: new_person_id)

    # Update messages where this alias is the sender (in batches for large datasets)
    Message.where(sender_id: alias_id)
           .where.not(sender_person_id: new_person_id)
           .in_batches(of: 1000)
           .update_all(sender_person_id: new_person_id)

    # Update mentions where this alias is mentioned
    Mention.where(alias_id: alias_id)
           .where.not(person_id: new_person_id)
           .update_all(person_id: new_person_id)
  end
end
