# coding: utf-8
require 'active_support/all'
require 'eventbrite-client'
require 'oauth2'
require 'sinatra'
require 'sinatra/config_file'

enable :sessions


configure do
  if settings.development?
    # So we can see what's going wrong on Heroku.
    set :show_exceptions, true
  end

  config_file './config.yml'

  # Overwrite config.yml settings if there are ENV variables.
  if ENV['EVENTBRITE_APPLICATION_KEY'] != nil or ENV['EVENTBRITE_CLIENT_SECRET'] != nil
    set :eventbrite_application_key, ENV['EVENTBRITE_APPLICATION_KEY']
    set :eventbrite_client_secret, ENV['EVENTBRITE_CLIENT_SECRET']
  end
end


helpers do
  def format_title
    "Eventbrite"
  end

  def auth_client 
    @auth_client ||= OAuth2::Client.new(
      settings.eventbrite_application_key, settings.eventbrite_client_secret, {
        :site => 'https://www.eventbrite.com',
        :authorize_url => '/oauth/authorize',
        :token_url => '/oauth/token'
      }
    )
  end 
end


error 400..500 do
  @message = body[0]
  erb :error
end


get '/favicon.ico' do
  status 410
end


get '/' do
end


get '/configure/' do
  return 400, 'No return_url parameter was provided' if !params['return_url']

  # Save these for use when the user returns.
  session[:bergcloud_return_url] = params['return_url']
  session[:bergcloud_error_url] = params['error_url']

  redirect auth_client.auth_code.authorize_url(
    :redirect_uri => url('/return/'),
    :response_type => 'code'
  )
end


get '/return/' do
  return 500, "No code was returned by Eventbrite" if !params[:code]

  begin
    access_token_obj = auth_client.auth_code.get_token(params[:code], {
        :redirect_uri => url('/return/'),
        :token_method => :post
      })
  rescue
    return 401, "Something went wrong when trying to authenticate with Eventbrite."
  end

  redirect "#{session[:bergcloud_return_url]}?config[access_token]=#{access_token_obj.token}"
end


get '/edition/' do
  return 401, "No access_token received" if !params[:access_token]

  access_token = params[:access_token]
  local_delivery_time = params[:local_delivery_time]

  eb_client = EventbriteClient.new({:access_token => access_token})

  begin
    response = eb_client.user_list_tickets({:type => 'all'})
  rescue RuntimeError => error
    # Yeah, when there are no results, Eventbrite seems to report an 'error',
    # which eventbrite-client raises as a RuntimeError.
    etag Digest::MD5.hexdigest(access_token + Date.today.strftime('%d%m%Y'))
    return 204, "No tickets found: #{error}"
  rescue => error
    return 500, "Something went wrong fetching tickets for the user: #{error}"
  end

  printer_time = Time.strptime(local_delivery_time, '%Y-%m-%dT%H:%M:%S%z')

  response['user_tickets'][1]['orders'].each do |order|
    # The timezone string is like 'Europe/London'.
    Time.zone = order['order']['event']['timezone']
    event_time = Time.zone.parse(order['order']['event']['start_date'])

    p "PRINTER: #{printer_time}, EVENT: #{event_time}"

    if event_time - printer_time < 86400
      p "EVENT #{order['order']['event']['title']} is within 24 hours"
    end

  end



  # Using id or whatever user-unique entity we have at this point:
  etag Digest::MD5.hexdigest(access_token + Date.today.strftime('%d%m%Y'))
  # Testing, always changing etag:
  # etag Digest::MD5.hexdigest(Time.now.strftime('%S%M%H-%d%m%Y'))
  erb :publication
end


get '/sample/' do
  etag Digest::MD5.hexdigest('sample' + Date.today.strftime('%d%m%Y'))
  erb :publication
end


post '/validate_config/' do
end

