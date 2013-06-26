# coding: utf-8
require 'active_support/all'
require 'eventbrite-client'
require 'json'
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
  def auth_client 
    @auth_client ||= OAuth2::Client.new(
      settings.eventbrite_application_key, settings.eventbrite_client_secret, {
        :site => 'https://www.eventbrite.com',
        :authorize_url => '/oauth/authorize',
        :token_url => '/oauth/token'
      }
    )
  end

  def format_title
    "Eventbrite"
  end

  # Used in the template for pluralizing words.
  def pluralize(num, word, ext='s')
    if num.to_i == 1
      return num.to_s + ' ' + word
    else
      return num.to_s + ' ' + word + ext
    end
  end

  # Formats a time period nicely.
  # start_time and end_time are like '2013-06-25 09:00:00'.
  # timezone is like 'Europe/London'.
  def format_time_period(start_time, end_time, timezone)
    Time.zone = timezone
    st = Time.zone.parse(start_time)
    et = Time.zone.parse(end_time)
    if st.strftime('%Y') != et.strftime('%Y')
      "#{st.strftime('%H:%M %a, %-d %b %Y')} to <span>#{et.strftime('%H:%M %a, %-d %b %Y (%Z)')}</span>"
    elsif st.strftime('%m') != et.strftime('%m')
      "#{st.strftime('%H:%M %a, %-d %b')} to <span>#{et.strftime('%H:%M %a, %-d %b %Y (%Z)')}</span>"
    elsif st.strftime('%d') != et.strftime('%d')
      "#{st.strftime('%H:%M %a, %-d %b')} to <span>#{et.strftime('%H:%M %a, %-d %b %Y (%Z)')}</span>"
    else
      "#{st.strftime('%H:%M')} to <span>#{et.strftime('%H:%M, %a, %-d %b %Y (%Z)')}</span>"
    end
  end


  # Returns the HTML for a venue's address.
  def format_address(venue)
    lines = []
    # The order we want the liens to appear in:
    if venue.include?('name') && venue['name'] != ''
      lines << "#{venue['name']}"
    end
    if venue.include?('address') && venue['address'] != ''
      lines << "#{venue['address']}"
    end
    if venue.include?('address_2') && venue['address_2'] != ''
      lines << "#{venue['address_2']}"
    end
    if venue.include?('city') && venue['city'] != '' && venue.include?('postal_code') && venue['postal_code'] != ''
      lines << "#{venue['city']} #{venue['postal_code']}"
    elsif venue.include?('city') && venue['city'] != ''
      lines << "#{venue['city']}"
    elsif venue.include?('postal_code') && venue['postal_code'] != ''
      lines << "#{venue['postal_code']}"
    end
    lines[0] = "<strong>#{lines[0]}</strong>"
    lines.join('<br />')
  end

  # Just trim off the '?ref=ebapi' from URLs as it makes them too long.
  def format_url(url)
    url.sub!(/\?ref\=ebapi/, '')
    url.sub!(/http\:\/\//, '')
    url.sub!(/\/$/, '')
    return url
  end

  def format_number_text(num)
    if num.to_i <= 10
      ['one', 'two', 'three', 'four', 'five',
                      'six', 'seven', 'eight', 'nine', 'ten'][ (num.to_i-1) ]
    else
      num
    end
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

  # Get the raw user, event, ticket data from Eventbrite API:

  @user = []
  begin
    response = eb_client.user_get()
    @user = response['user']
  rescue => error
    return 500, "Something went wrong fetching the user's data: #{error}"
  end

  # Events the user has organised:
  event_data = []
  begin
    response = eb_client.user_list_events({:do_not_display => 'style,tickets'})
    event_data = response['events']
  rescue RuntimeError => error
    # No events.
  rescue => error
    return 500, "Something went wrong fetching events for the user: #{error}"
  end

  # Tickets the user has bought:
  ticket_data = []
  begin
    response = eb_client.user_list_tickets({:type => 'all'})
    ticket_data = response['user_tickets'][1]['orders']
  rescue RuntimeError => error
    # Yeah, when there are no results, Eventbrite seems to report an 'error',
    # which eventbrite-client raises as a RuntimeError.
  rescue => error
    return 500, "Something went wrong fetching tickets for the user: #{error}"
  end

  if ticket_data.length == 0 && event_data.length == 0
    etag Digest::MD5.hexdigest(access_token + Date.today.strftime('%d%m%Y'))
    return 204, "No tickets found."
  end

  # We have some events/tickets, so we'll now see if they're tomorrow.

  # Get the next midnight datetime:
  printer_time = Time.strptime(local_delivery_time, '%Y-%m-%dT%H:%M:%S%z')
  printer_time_tomorrow = printer_time + 86400
  printer_time_tomorrow_midnight = Time.strptime(
    printer_time_tomorrow.strftime('%Y-%m-%dT00:00:00%z'),'%Y-%m-%dT%H:%M:%S%z'
  )

  # What we'll pass to the template.
  @events = []
  @tickets = []
  # We'll keep track of any events we're going to display,
  # just so we can compare with tickets:
  event_ids = []

  event_data.each do |event|
    # The timezone string is like 'Europe/London'.
    Time.zone = event['event']['timezone']
    event_time = Time.zone.parse(event['event']['start_date'])

    if event_time - printer_time_tomorrow_midnight < 86400
      @events << event['event']
      event_ids << event['event']['id']
    end
  end

  ticket_data.each do |order|
    # The timezone string is like 'Europe/London'.
    Time.zone = order['order']['event']['timezone']
    event_time = Time.zone.parse(order['order']['event']['start_date'])

    # We want tickets for events starting tomorrow, but not if we've already
    # got them listed as events the user has organised.
    if event_time - printer_time_tomorrow_midnight < 86400
      if ! event_ids.include?(order['order']['event']['id'])
        @tickets << order['order']
      end
    end
  end

  # @events and @tickets should now contain stuff we actually want to print.

  # Using id or whatever user-unique entity we have at this point:
  etag Digest::MD5.hexdigest(access_token + Date.today.strftime('%d%m%Y'))
  # Testing, always changing etag:
  # etag Digest::MD5.hexdigest(Time.now.strftime('%S%M%H-%d%m%Y'))
  erb :publication
end


# /sample/ will show the default sample.
# The URL can be extended to show different numbers of events and tickets, eg:
# /sample/events/2/
# /sample/events/1/tickets/2/
# /sample/tickets/0/events/1/
# /sample/tickets/2/events/2/
# etc.
# We only have 2 events/tickets in sample data, so further items will be
# repeats of those.
get %r{/sample/(?:([\w]+)/([\d])/)?(?:([\w]+)/([\d])/)?} do

  if params[:captures]
    show_events = 0
    show_tickets = 0 
    if params[:captures][0] == 'events'
      show_events = params[:captures][1].to_i
    end
    if params[:captures][2] == 'events'
      show_events = params[:captures][3].to_i
    end
    if params[:captures][0] == 'tickets'
      show_tickets = params[:captures][1].to_i
    end
    if params[:captures][2] == 'tickets'
      show_tickets = params[:captures][3].to_i
    end
  else
    # Standard sample.    
    show_events = 0 
    show_tickets = 1
  end

  @user = {
    'first_name' => "Francis",
    'last_name' => "Overton",
    'user_id' => 999999,
    'date_modified' => "2013-06-24 05:29:28",
    'date_created' => "2009-10-11 09:40:05",
    'email' => "francis@example.com"
  }

  if show_events == 0
    @events = []
  else
    @events = JSON.parse( IO.read(Dir.pwd + '/samples/events.json') )
    @events = @events[0, show_events]
    # A bit ugly, but add repeating events on until we hit our required number.
    if show_events > 2
      for n in 2...show_events
        @events[n] = @events[n % 2]
      end
    end
  end

  if show_tickets == 0
    @tickets = []
  else
    @tickets = JSON.parse( IO.read(Dir.pwd + '/samples/tickets.json') )
    @tickets = @tickets[0, show_tickets]
    # A bit ugly, but add repeating tickets on until we hit our required number.
    if show_tickets > 2
      for n in 2...show_tickets
        @tickets[n] = @tickets[n % 2]
      end
    end
  end

  @all_events = @events.dup + @tickets.map{|t| t['event']}

  etag Digest::MD5.hexdigest('sample' + Date.today.strftime('%d%m%Y'))
  erb :publication
end


post '/validate_config/' do
end

