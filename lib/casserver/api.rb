require 'casserver/utils'
require 'casserver/cas'
require 'casserver/base'
require 'casserver/server'

require 'logger'
#$LOG ||= Logger.new(STDOUT)
$LOG = Logger.new(STDOUT)

module CASServer
  class APIServer < CASServer::Server
    # TODO change that for some CAS helpers
    include CASServer::CAS

    def self.settings
      self
    end

    # :category: API
    #
    # return:: Status code: 204
    get '#{uri_path}/api-isalive', :provides => [:json, :xml] do
      status 204
    end

    # :category: API
    #
    # === return
    # Status:: Status code: 200, 203
    # xml:: NOT IMPLEMENTED
    # json:: {:type => "confirmation", :message => "You have successfully logged out."}
    #        {:type => "notice", :message => "Your granting ticket is invalid."}
    #        {:type => "confirmation", :service => params[:service] }
    delete "#{uri_path}/api-logout", :provides => [:json, :xml] do
      @replay = {}
      tgt = CASServer::Model::TicketGrantingTicket.find_by_ticket(request.cookies['tgt'])

      if tgt
        CASServer::Model::TicketGrantingTicket.transaction do
          tgt.granted_service_tickets.each do |st|
            # TODO this must be send in background because block app server
            send_logout_notification_for_service_ticket(st) if settings.config[:enable_single_sign_out]
            st.destroy
          end
          pgts = CASServer::Model::ProxyGrantingTicket.find(:all,
                                                            :conditions => [CASServer::Model::TicketGrantingTicket.connection.quote_table_name(CASServer::Model::ServiceTicket.table_name)+".username = ?", tgt.username],
                                                            :include => :service_ticket)
          pgts.each do |pgt|
            $LOG.debug("Deleting Proxy-Granting Ticket '#{pgt}' for user '#{pgt.service_ticket.username}'")
            pgt.destroy
          end
          $LOG.debug("Deleting #{tgt.class.name.demodulize} '#{tgt}' for user '#{tgt.username}'")
          tgt.destroy
        end

        $LOG.info("User '#{tgt.username}' logged out.")
        @replay[:type] = "confirmation"
        @replay[:message] = t.notice.successfull_logged_out
        status 200
      else
        @replay[:type] = "notice"
        @replay[:message] = t.error.invalid_granting_ticket
        status 203
      end

      if tgt
        CASServer::Model::TicketGrantingTicket.transaction do
          $LOG.debug("Deleting Service/Proxy Tickets for '#{tgt}' for user '#{tgt.username}'")
          tgt.granted_service_tickets.each do |st|
            send_logout_notification_for_service_ticket(st) if settings.config[:enable_single_sign_out]
            # TODO: Maybe we should do some special handling if send_logout_notification_for_service_ticket fails?
            #       (the above method returns false if the POST results in a non-200 HTTP response).
            $LOG.debug "Deleting #{st.class.name.demodulize} #{st.ticket.inspect} for service #{st.service}."
            st.destroy
          end

          pgts = CASServer::Model::ProxyGrantingTicket.find(:all,
                                                            :conditions => [CASServer::Model::ServiceTicket.quoted_table_name+".username = ?", tgt.username],
                                                            :include => :service_ticket)
          pgts.each do |pgt|
            $LOG.debug("Deleting Proxy-Granting Ticket '#{pgt}' for user '#{pgt.service_ticket.username}'")
            pgt.destroy
          end

          $LOG.debug("Deleting #{tgt.class.name.demodulize} '#{tgt}' for user '#{tgt.username}'")
          tgt.destroy
        end

        $LOG.info("User '#{tgt.username}' logged out.")
      else
        $LOG.warn("User tried to log out without a valid ticket-granting ticket.")
      end

      prepare_replay_for(request)
    end

    # :category: API
    #
    # return:: Status code: 201, 404, 401
    post "#{uri_path}/api-login", :provides => [:json, :xml] do
      @replay = {}
      service = clean_service_url(params['service'])
      username = params['username'].to_s.strip
      password = params['password']

      username.downcase! if username && settings.config[:downcase_username]

      credentials_are_valid = false
      extra_attributes = {}
      successful_authenticator = nil

      begin
        auth_index = 0
        settings.auth.each do |auth_class|
          auth = auth_class.new

          auth_config = settings.config[:authenticator][auth_index]
          # pass the authenticator index to the configuration hash in case the authenticator needs to know
          # it splace in the authenticator queue
          auth.configure(auth_config.merge('auth_index' => auth_index))

          credentials_are_valid = auth.validate(
              :username => username,
              :password => password,
              :service => service,
              :request => env
          )
          if credentials_are_valid
            extra_attributes.merge!(auth.extra_attributes) unless auth.extra_attributes.blank?
            successful_authenticator = auth
            break
          end

          auth_index += 1
        end

        if credentials_are_valid
          tgt = generate_ticket_granting_ticket(username, extra_attributes)
          @replay[:type] = "confirmation"
          @replay[:tgt] = tgt.to_s

          if service.blank?
            @replay[:message] = t.notice.successfull_logged_in
            status 201
          else
            # TODO
            st = generate_service_ticket(service, username, tgt)

            begin
              service_with_ticket = service_uri_with_ticket(service, st)

              $LOG.info("Redirecting authenticated user '#{username}' at '#{st.client_hostname}' to service '#{service}'")
              raise NotImplementedError
                #redirect service_with_ticket, 303 # response code 303 means "See Other" (see Appendix B in CAS Protocol spec)
            rescue URI::InvalidURIError
              $LOG.error("The service '#{service}' is not a valid URI!")
              @replay[:message] = t.error.invalid_target_service
              @replay[:type] = 'error'
            end
          end
        else
          $LOG.warn("Invalid credentials given for user '#{username}'")
          @replay[:type] = 'error'
          @replay[:message] = t.error.incorrect_username_or_password
          status 401
        end
      rescue CASServer::AuthenticatorError => e
        $LOG.error(e)
        @replay[:type] = 'error'
        @replay[:message] = e.to_s
        status 401
      end
      prepare_replay_for(request)
    end


    ## :category: API
    ##
    ## return:: Status code:
    #get '/loginTicket' do
    #  raise NotImplementedError
    #end
    #
    ## :category: API
    ##
    ## return:: Status code:
    #get '/validate' do
    #  raise NotImplementedError
    #end
    #
    ## :category: API
    ##
    ## return:: Status code:
    #get '/validate' do
    #  raise NotImplementedError
    #end
    #
    ## :category: API
    ##
    ## return:: Status code:
    #get '/serviceValidate' do
    #  raise NotImplementedError
    #end
    #
    ## :category: API
    ##
    ## return:: Status code:
    #get '/proxyValidate' do
    #  raise NotImplementedError
    #end
    #
    ## :category: API
    ##
    ## return:: Status code:
    #get '/proxy' do
    #  raise NotImplementedError
    #end

    private
    def prepare_replay_for(request)
      if request.accept? 'application/json'
        return @replay.to_json
      end
      if request.accept? 'application/xml'
        # TODO
        raise "NotImplementedError"
      end
    end
  end
end
