module ApplicationHelper
  # Smart time display: relative for recent, absolute for old
  def smart_time_display(time)
    return "" if time.nil?

    time_ago = Time.current - time
    same_year = time.year == Time.current.year

    # Less than 7 days: show relative time
    if time_ago < 7.days
      time_ago_in_words(time) + " ago"
    # Same year, older than 7 days: show month and day with time
    elsif same_year
      time.strftime("%b %d, %H:%M")
    # Different year: show full date
    else
      time.strftime("%b %d, %Y")
    end
  end

  def absolute_time_display(time)
    return "" if time.nil?
    time.strftime("%B %d, %Y at %I:%M %p")
  end

  def render_message_body(body)
    QuotedEmailFormatter.new(body.to_s).to_html.html_safe
  end

  def message_dom_id(message)
    "message-#{message.id}"
  end

  def message_id_anchor(message)
    return nil if message.message_id.blank?
    "message-id-#{CGI.escape(message.message_id)}"
  end

  def commitfest_ci_label(summary)
    case summary[:ci_status]
    when "not_processed"
      "Not processed"
    when "needs_rebase"
      "Needs rebase"
    when "score"
      "CI score: #{summary[:ci_score].to_i}/10"
    end
  end

  def commitfest_icon_class(summary)
    return "fa-circle-check" if summary[:committed]
    return "fa-magnifying-glass" if summary[:status] == "Needs review"

    "fa-code-branch"
  end

  def read_visibility_seconds
    5
  end

  def display_name_for_user(user)
    return "Unknown" unless user
    user.primary_alias&.name || user.username || "User ##{user.id}"
  end

  def note_mention_label(mention)
    mentionable = mention.mentionable
    case mentionable
    when User
      username = mentionable.username.presence || display_name_for_user(mentionable)
      "@#{username}"
    when Team
      "@#{mentionable.name}"
    else
      "@unknown"
    end
  end

  def can_remove_note_mention?(mention, user)
    return false unless user
    mentionable = mention.mentionable

    case mentionable
    when User
      mentionable.id == user.id
    when Team
      mentionable.admin?(user)
    else
      false
    end
  end

  def contributor_role_badge(contributor, compact: false)
    return nil unless contributor&.respond_to?(:contributor_type)
    contributor_type = contributor.contributor_type
    return nil unless contributor_type

    label = contributor.respond_to?(:contributor_badge) ? contributor.contributor_badge : contributor_type
    label = label.presence || "Contributor"

    icon_class =
      case contributor_type
      when "core_team"
        "fa-people-group"
      when "committer"
        "fa-code-branch"
      when "major_contributor"
        "fa-star"
      when "significant_contributor"
        "fa-award"
      when "past_major_contributor", "past_significant_contributor"
        "fa-clock-rotate-left"
      end

    return nil unless icon_class

    classes = ["role-badge", "role-badge-#{contributor_type.tr('_', '-')}"]
    classes << "is-compact" if compact

    content_tag(:span, class: classes.join(" "), title: label, "aria-label": label) do
      concat content_tag(:i, "", class: "fa-solid #{icon_class}")
      concat content_tag(:span, label, class: "role-badge-label") unless compact
    end
  end
end
