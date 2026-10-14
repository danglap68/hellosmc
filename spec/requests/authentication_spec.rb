require "rails_helper"

RSpec.describe "Authentication" do
  let!(:user) { create(:user, :admin, email: "admin@hellosmc.vn", password: "Password-12345") }

  it "redirects anonymous visitors to the login page" do
    get "/admin"
    expect(response).to redirect_to(new_user_session_path)
  end

  it "renders the Vietnamese login page" do
    get new_user_session_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Đăng nhập")
  end

  it "signs in with valid credentials" do
    post user_session_path, params: { user: { email: "admin@hellosmc.vn", password: "Password-12345" } }
    expect(response).to redirect_to(admin_root_path)
  end

  it "refuses inactive users" do
    user.update!(active: false)
    post user_session_path, params: { user: { email: "admin@hellosmc.vn", password: "Password-12345" } }
    get "/admin"
    expect(response).to redirect_to(new_user_session_path)
  end

  it "has no public registration" do
    get "/users/sign_up"
    expect(response).to have_http_status(:not_found)
  end

  it "signs out" do
    sign_in user
    delete destroy_user_session_path
    get "/admin"
    expect(response).to redirect_to(new_user_session_path)
  end

  it "does not redirect an expired session to an external Referer on POST" do
    post user_session_path, params: { user: { email: user.email, password: "Password-12345" } }
    get admin_root_path
    travel 9.hours
    post admin_bulk_actions_path, params: { resource: "users", operation: "destroy", ids: [ user.id ] },
         headers: { "HTTP_REFERER" => "https://attacker.example/fake-login" }

    expect(response).to have_http_status(:redirect)
    expect(URI.parse(response.location).host).to eq("www.example.com")
    expect(response.location).not_to include("attacker.example")
    expect(user.reload).to be_active
  end

  it "accepts a reset token once and authenticates only with the new password" do
    token = user.send_reset_password_instructions
    patch user_password_path, params: { user: { reset_password_token: token,
      password: "New-Password-12345", password_confirmation: "New-Password-12345" } }
    expect(response).to have_http_status(:redirect)
    expect(user.reload.valid_password?("New-Password-12345")).to be(true)
    expect(user.valid_password?("Password-12345")).to be(false)
    expect(user.reset_password_token).to be_nil

    sign_out user
    patch user_password_path, params: { user: { reset_password_token: token,
      password: "Reused-Password-12345", password_confirmation: "Reused-Password-12345" } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.valid_password?("New-Password-12345")).to be(true)
  end

  it "offers password reset" do
    get new_user_password_path
    expect(response).to have_http_status(:ok)
    expect {
      post user_password_path, params: { user: { email: "admin@hellosmc.vn" } }
    }.to change(ActionMailer::Base.deliveries, :count).by(1)

    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Đặt lại mật khẩu SMC")
    expect(mail.parts.map(&:mime_type)).to contain_exactly("text/plain", "text/html")
    expect(mail.html_part.body.decoded).to include("Đặt mật khẩu mới", "/users/password/edit?reset_password_token=")
    expect(mail.text_part.body.decoded).to include("/users/password/edit?reset_password_token=")
  end
end
