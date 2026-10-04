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
