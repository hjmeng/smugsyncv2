require 'oauth/request_proxy/base'
module Smugsyncv2
  class Client
    TOKEN_FILE = '/tmp/.token_cache'

    def initialize(key, secret, user_token, user_secret, logger = false)
      @uris = nil
      @key = key
      @secret = secret
      @user_token = user_token
      @user_secret = user_secret
      @logger = logger
    end

    def oauth_opts
      { site: OAUTH_ORIGIN,
        request_token_path: REQUEST_TOKEN_PATH,
        access_token_path: ACCESS_TOKEN_PATH,
        authorize_path: AUTHORIZE_PATH
      }
    end

    def login # rubocop:disable Metrics/MethodLength
      @consumer = OAuth::Consumer.new(@key, @secret, oauth_opts)
      if (!@user_token.empty? && !@user_secret.empty?) 
        @access_token = OAuth::AccessToken.new(@consumer, @user_token, @user_secret)
        return @access_token
      end
      
      if File.exist?(TOKEN_FILE)
        @access_token = load_cached_token 
        return @access_token
      end

      @request_token = @consumer.get_request_token
      authorize_url = @request_token.authorize_url + '&Access=Full'
      puts "Open a web browser and open: #{authorize_url}"
      puts 'Enter the validation code: '
      verification_code = STDIN.gets.chomp
      @access_token = @request_token.get_access_token(
      oauth_verifier: verification_code)
      cache_token(@access_token)
      @access_token
    end

    def access_token
      @access_token ||= login
    end

    def consumer
      if @consumer
        @consumer
      else
        login
        @consumer
      end
    end

    def load_cached_token
      Marshal.load(File.open(TOKEN_FILE, 'r'))
    end

    def cache_token(token)
      File.open(TOKEN_FILE, 'w') do |file|
        file.write Marshal.dump(token)
      end
    end

    def adapter(url: BASE_URL)
      @connection = Faraday.new(url: url) do |conn|
        conn.request :json
        conn.response :json
        conn.adapter Faraday.default_adapter
        conn.response :logger if @logger
      end
    end

    def connection(**args)
      @connection ||= adapter(**args)
    end

    def get_oauth_header(method, url, params)
      SimpleOAuth::Header.new(
      method, url,
      params,
      consumer_key: @key,
      consumer_secret: @secret,
      token: access_token.token,
      token_secret: access_token.secret,
      version: '1.0').to_s
    end

    def request(method: :get, path: nil, params: {}, body: {}, headers: {})
      url = path.nil? ? BASE_URL : File.join(API_ORIGIN, path)
      base_headers = { 'User-Agent' => USER_AGENT, 'Accept' => 'application/json' }
      headers = base_headers.merge(headers || {})

      adapter(url: url)
      request = Typhoeus::Request.new(
        url,
        method: method,
        body: body,
        params: params,
        headers: {'Authorization' => get_oauth_header(method, url, params)}.merge!(headers)
      )
      response = request.run
      if response.body.blank?
        url = File.join(API_ORIGIN,response.headers['location'])
           request = Typhoeus::Request.new(
            url,
            method: method,
            body: body,
            params: params,
            headers: {'Authorization' => get_oauth_header(method, url, params)}.merge!(headers)
          )
        response = request.run
      end
      @response = DeepOpenStruct.load({body: JSON.parse(response.body), headers: response.headers})

    end

    def user
      res = request
      uri = res.body.Response.Uris.AuthUser.Uri
      user = request(path: uri)
      user = user.body.Response.User.Uris
      @uris = user
    end

    def get_uri(name)
      uri = @uris.send(name).Uri
      request(path: uri)
      if @response.body && @response.body.Response && @response.body.Response.send(name)
        @uris = @response['body']['Response'][name]['Uris']
      end
      @response
    end
  end
end
