require "ruby-saml"

class Devise::SamlSessionsController < Devise::SessionsController
  include DeviseSamlAuthenticatable::SamlConfig
  unloadable if Rails::VERSION::MAJOR < 4
  if Rails::VERSION::MAJOR < 5
    skip_before_filter :verify_authenticity_token
    prepend_before_filter :store_info_for_sp_initiated_logout, only: :destroy
  else
    skip_before_action :verify_authenticity_token, raise: false
    prepend_before_action :store_info_for_sp_initiated_logout, only: :destroy
  end

  def new
    idp_entity_id = get_idp_entity_id(params)
    request = OneLogin::RubySaml::Authrequest.new
    auth_params = { RelayState: relay_state } if relay_state
    action = request.create(saml_config(idp_entity_id), auth_params || {})
    redirect_to action
  end

  def metadata
    meta = OneLogin::RubySaml::Metadata.new
    render :xml => meta.generate(saml_config)
  end

  def idp_sign_out
    if params[:SAMLRequest] && Devise.saml_session_index_key
      saml_config = saml_config(get_idp_entity_id(params))
      logout_request = OneLogin::RubySaml::SloLogoutrequest.new(params[:SAMLRequest], settings: saml_config)
      resource_class.reset_session_key_for(logout_request.name_id)

      redirect_to generate_idp_logout_response(saml_config, logout_request.id)
    elsif params[:SAMLResponse]
      #Currently Devise handles the session invalidation when the request is made.
      #To support a true SP initiated logout response, the request ID would have to be tracked and session invalidated
      #based on that.
      if Devise.saml_sign_out_success_url
        redirect_to Devise.saml_sign_out_success_url
      else
        redirect_to action: :new
      end
    else
      head :invalid_request
    end
  end

  protected

  # For non transient name ID, save info to identify user for logout purpose
  # before that user's session got destroyed. These info are used in the
  # `after_sign_out_path_for` method below.
  def store_info_for_sp_initiated_logout
      return unless FeatureSetting.saml_logout_requests_signed?
      @name_identifier_value_for_sp_initiated_logout = current_user.authentications.find_by(provider: 'saml').secret
      @sessionindex_for_sp_initiated_logout = Devise.saml_session_index_key ? current_user.send(Devise.saml_session_index_key) : nil
    end


  def relay_state
    @relay_state ||= if Devise.saml_relay_state.present?
      Devise.saml_relay_state.call(request)
    end
  end

  # Override devise to send user to IdP logout for SLO
  def after_sign_out_path_for(_)
    idp_entity_id = get_idp_entity_id(params)
    request = OneLogin::RubySaml::Logoutrequest.new
    saml_settings = saml_config(idp_entity_id).dup
    # Add attributes to saml_settings which will later be used to create the SP
    # initiated logout request
    if FeatureSetting.saml_logout_requests_signed?
      saml_settings.name_identifier_value = @name_identifier_value_for_sp_initiated_logout
      saml_settings.sessionindex = @sessionindex_for_sp_initiated_logout
      @name_identifier_value_for_sp_initiated_logout = nil
      @sessionindex_for_sp_initiated_logout = nil
    end

    request.create(saml_settings)
  end

  def generate_idp_logout_response(saml_config, logout_request_id)
    OneLogin::RubySaml::SloLogoutresponse.new.create(saml_config, logout_request_id, nil)
  end
end
