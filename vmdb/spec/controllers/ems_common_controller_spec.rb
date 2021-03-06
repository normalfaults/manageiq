require "spec_helper"

describe EmsCloudController do
  context "::EmsCommon" do
    context "#get_form_vars" do
      it "check if the default port for openstack/rhevm is set" do
        controller.instance_variable_set(:@model, EmsCloud)
        controller.instance_variable_set(:@edit, {:new => {}})
        controller.instance_variable_set(:@_params, {:server_emstype => "openstack"})
        controller.send(:get_form_vars)
        assigns(:edit)[:new][:port].should == 5000

        controller.instance_variable_set(:@_params, {:server_emstype => "ec2"})
        controller.send(:get_form_vars)
        assigns(:edit)[:new][:port].should == nil
      end
    end

    context "#form_field_changed" do
      before :each do
        set_user_privileges
      end
      
      it "form_div should be updated when server type is sent up" do
        controller.instance_variable_set(:@edit, {:new => {}, :key => "ems_edit__new"})
        session[:edit] = assigns(:edit)
        post :form_field_changed, :server_emstype => "rhevm", :id => "new"
        response.body.should include("form_div")
      end

      it "form_div should not be updated when other fields are sent up" do
        controller.instance_variable_set(:@edit, {:new => {}, :key => "ems_edit__new"})
        session[:edit] = assigns(:edit)
        post :form_field_changed, :name => "Test", :id => "new"
        response.body.should_not include("form_div")
      end
    end

    context "#create" do
      it "displays correct attribute name in error message when adding Amazon EMS" do
        set_user_privileges
        controller.instance_variable_set(:@model, EmsCloud)
        controller.instance_variable_set(:@edit, {:new => {:name => "EMS 1", :emstype => "ec2"},
                                                  :key => "ems_edit__new"})
        session[:edit] = assigns(:edit)
        controller.stub(:drop_breadcrumb)
        post :create, :button => "add"
        flash_messages = assigns(:flash_array)
        flash_messages.first[:message].should include("Region is not included in the list")
        flash_messages.first[:level].should == :error
      end

      it "displays correct attribute name in error message when adding non-Amazon EMS" do
        set_user_privileges
        controller.instance_variable_set(:@model, EmsCloud)
        controller.instance_variable_set(:@edit, {:new => {:name => "EMS 2", :emstype => "rhevm"},
                                                  :key => "ems_edit__new"})
        session[:edit] = assigns(:edit)
        controller.stub(:drop_breadcrumb)
        post :create, :button => "add"
        flash_messages = assigns(:flash_array)
        flash_messages.first[:message].should include("Host Name can't be blank")
        flash_messages.first[:level].should == :error
      end
    end
  end
end
