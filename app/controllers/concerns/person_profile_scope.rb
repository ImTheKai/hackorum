module PersonProfileScope
  extend ActiveSupport::Concern

  included do
    before_action :load_person
  end

  private

  def load_person
    @person = find_person
    @primary_alias = @person.default_alias
    @aliases = @person.aliases.with_sent_messages.order(:email)
    @profile_email = profile_email
  end

  def find_person
    email_param = params[:email].to_s
    person = Person.find_by_email(email_param)
    return Person.includes(:aliases, :default_alias).find(person.id) if person

    if email_param.match?(/\A\d+\z/)
      return Person.includes(:aliases, :default_alias).find(email_param)
    end

    raise ActiveRecord::RecordNotFound
  end

  def profile_email
    @primary_alias&.email || @aliases.first&.email || params[:email].to_s
  end

  def activity_person_ids
    @person.id
  end
end
