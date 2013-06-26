# Eventbrite Little Printer publication

This publication (written in Ruby with Sinatra) displays any events for the subscribed user which are starting the following day. Where, by "events", we mean events the user has created, or events the user has bought tickets to.

The subscribing user must have an Eventbrite account (it's possible to buy tickets on Eventbrite without an account).

This app requires an Eventbrite API key, from https://www.eventbrite.com/api/key/

Add the key and secret *either* in environment variables like:

    EVENTBRITE_APPLICATION_KEY: GB1234567890ABCDEF
    EVENTBRITE_CLIENT_SECRET: 1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890ABCD

or in a `config.yml` file in the root level of the directory:

    eventbrite_application_key: GB1234567890ABCDEF
    eventbrite_client_secret: 1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890ABCD

This publication is a good example of:

* Authenticating with Eventbrite using OAuth2.
* Fetching data for a user from the Eventbrite API.

[More about the Eventbrite API.](http://developer.eventbrite.com/)

----

BERG Cloud Developer documentation: http://remote.bergcloud.com/developers/

