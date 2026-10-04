class ApplicationMailer < ActionMailer::Base
  # A proc, not a lambda: Devise evaluates it with an argument.
  default from: proc { AppConfig.mailer_sender }
  layout "mailer"
  helper MailerHelper
end
