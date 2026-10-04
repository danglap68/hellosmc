class ApplicationMailer < ActionMailer::Base
  default from: -> { AppConfig.mailer_sender }
  layout "mailer"
end
