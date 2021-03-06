require 'spec_helper'

describe "Login process" do
  before(:each) do
    Vmdb::Application.config.secret_token = 'x' * 40
    guid, server, zone, admin_user, admin_group, admin_role = EvmSpecHelper::seed_admin_user_and_friends
  end

  context "w/o a valid session" do
    pending "these tests are failing on CC monitor" do
      it "redirects to 'login'" do
        get '/dashboard/show'
        expect(response).to redirect_to(:controller => 'dashboard', :action => 'login')
      end

      it "redirects to 'login' and sets start_url for whitelisted entry point" do
        get '/host/show/10'
        expect(response).to redirect_to(:controller => 'dashboard', :action => 'login')
        expect(session[:start_url]).to eq('http://www.example.com/host/show/10')
      end

      it "allows login with correct password" do
        post '/dashboard/authenticate', :user_name => 'admin', :user_password => 'smartvm'
        expect(response.status).to eq(200)
        expect(response.body).not_to match /password you entered is incorrect/
      end

      it "does now allow login with incorrect password" do
        post '/dashboard/authenticate', :user_name => 'admin', :user_password => 'fantomas'
        expect(response.status).to eq(200)
        expect(response.body).to match /password you entered is incorrect/
      end
    end
  end
end
