# Development previews: /rails/mailers/devise_mailer
class DeviseMailerPreview < ActionMailer::Preview
  def reset_password_instructions
    Devise::Mailer.reset_password_instructions(user, "preview-token")
  end

  def password_change
    Devise::Mailer.password_change(user)
  end

  private

  def user
    User.first || User.new(email: "nguyen.van.a@example.com", name: "Nguyễn Văn A")
  end
end
