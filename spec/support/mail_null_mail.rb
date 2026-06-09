# ActionMailer returns ActionMailer::Base::NullMail when a mailer action returns
# early without calling mail(). Alias it under Mail::NullMail so specs can use
# the more intuitive constant.
module Mail
  NullMail = ActionMailer::Base::NullMail
end
