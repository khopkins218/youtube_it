class YouTubeIt

  module Upload
    class UploadError < YouTubeIt::Error; end
    class AuthenticationError < YouTubeIt::Error; end

    # Implements video uploads/updates/deletions
    #
    #   require 'youtube_it'
    #
    #   uploader = YouTubeIt::Upload::VideoUpload.new("user", "pass", "dev-key")
    #   uploader.upload File.open("test.m4v"), :title => 'test',
    #                                        :description => 'cool vid d00d',
    #                                        :category => 'People',
    #                                        :keywords => %w[cool blah test]
    #
    class VideoUpload
      include YouTubeIt::Logging
      def initialize user, pass, dev_key, client_id = 'youtube_it', access_token = nil
        @user, @pass, @dev_key, @client_id, @access_token = user, pass, dev_key, client_id, access_token
        @http_debugging = false
      end

      def enable_http_debugging
        @http_debugging = true
      end

      #
      # Upload "data" to youtube, where data is either an IO object or
      # raw file data.
      # The hash keys for opts (which specify video info) are as follows:
      #   :mime_type
      #   :filename
      #   :title
      #   :description
      #   :category
      #   :keywords
      #   :private
      # New V2 api hash keys for accessControl:
      #   :rate
      #   :comment
      #   :commentVote
      #   :videoRespond
      #   :list
      #   :embed
      #   :syndicate
      # Specifying :private will make the video private, otherwise it will be public.
      #
      # When one of the fields is invalid according to YouTube,
      # an UploadError will be raised. Its message contains a list of newline separated
      # errors, containing the key and its error code.
      #
      # When the authentication credentials are incorrect, an AuthenticationError will be raised.
      def upload data, opts = {}
        @opts = { :mime_type => 'video/mp4',
                  :title => '',
                  :description => '',
                  :category => '',
                  :keywords => [] }.merge(opts)

        @opts[:filename] ||= generate_uniq_filename_from(data)

        post_body_io = generate_upload_io(video_xml, data)

        upload_headers = {
            "X-GData-Key"    => "key=#{@dev_key}",
            "Slug"           => "#{@opts[:filename]}",
            "Content-Type"   => "multipart/related; boundary=#{boundary}",
            "Content-Length" => "#{post_body_io.expected_length}", # required per YouTube spec
          # "Transfer-Encoding" => "chunked" # We will stream instead of posting at once
        }

        if @access_token.nil?
          upload_headers.merge!(authorization_headers)
        end

        if @access_token.nil?
          http = Net::HTTP.new(uploads_url)
          http.set_debug_output(logger) if @http_debugging
          path = '/feeds/api/users/%s/uploads' % @user
          http.start do | session |
            # Use the chained IO as body so that Net::HTTP reads into the socket for us
            post = Net::HTTP::Post.new(path, upload_headers)
            post.body_stream = post_body_io
            response = session.request(post)
          end
        else
          url = 'http://%s/feeds/api/users/%s/uploads' % [uploads_url, @user]
          response = @access_token.post(url, post_body_io, upload_headers)
        end

        raise_on_faulty_response(response)
        return uploaded_video_id_from(response.body)
      end

      # Updates a video in YouTube.  Requires:
      #   :title
      #   :description
      #   :category
      #   :keywords
      # The following are optional attributes:
      #   :private
      # When the authentication credentials are incorrect, an AuthenticationError will be raised.
      def update(video_id, options)
        @opts = options

        update_body = video_xml

        update_header = {
          "X-GData-Key"    => "key=#{@dev_key}",
          "GData-Version" => "2",
          "Content-Type"   => "application/atom+xml",
          "Content-Length" => "#{update_body.length}",
        }

        if @access_token.nil?
          update_header.merge!(authorization_headers)
        end

        update_url = "/feeds/api/users/#{@user}/uploads/#{video_id}"

        if @access_token.nil?
          http = Net::HTTP.new(base_url)
          http.set_debug_output(logger) if @http_debugging
          response = http.put(update_url, update_body, update_header)
        else
          response = @access_token.put("http://"+base_url+update_url, update_body, update_header)
        end

        raise_on_faulty_response(response)
        return YouTubeIt::Parser::VideoFeedParser.new(response.body).parse
      end

      # Delete a video on YouTube
      def delete(video_id)
        delete_header = authorization_headers.merge({
          "X-GData-Key"    => "key=#{@dev_key}",
          "Content-Type"   => "application/atom+xml; charset=UTF-8",
          "Content-Length" => "0",
        })

        delete_url = "/feeds/api/users/#{@user}/uploads/#{video_id}"

        Net::HTTP.start(base_url) do |session|
          response = session.delete(delete_url, delete_header)
          raise_on_faulty_response(response)
          return true
        end
      end

      def get_upload_token(options, nexturl)
        @opts = options

        token_body    = video_xml
        token_header  = authorization_headers.merge({
          "X-GData-Key"    => "key=#{@dev_key}",
          "Content-Type"   => "application/atom+xml; charset=UTF-8",
          "Content-Length" => "#{token_body.length}",
        })
        token_url = "/action/GetUploadToken"

        Net::HTTP.start(base_url) do | session |
          response = session.post(token_url, token_body, token_header)
          raise_on_faulty_response(response)
          return {:url    => "#{response.body[/<url>(.+)<\/url>/, 1]}?nexturl=#{nexturl}",
                  :token  => response.body[/<token>(.+)<\/token>/, 1]}
        end
      end

      private

      def uploads_url
        ["uploads", base_url].join('.')
      end

      def base_url
        "gdata.youtube.com"
      end

      def boundary
        "An43094fu"
      end

      def authorization_headers
        {
          "Authorization"  => "GoogleLogin auth=#{auth_token}"
        }
      end

      def parse_upload_error_from(string)
        REXML::Document.new(string).elements["//errors"].inject('') do | all_faults, error|
          location = error.elements["location"].text[/media:group\/media:(.*)\/text\(\)/,1]
          code = error.elements["code"].text
          all_faults + sprintf("%s: %s\n", location, code)
        end
      end

      def raise_on_faulty_response(response)
        if response.code.to_i == 403
          raise AuthenticationError, response.body[/<TITLE>(.+)<\/TITLE>/, 1]
        elsif response.code.to_i / 10 != 20 # Response in 20x means success
          raise UploadError, parse_upload_error_from(response.body)
        end
      end

      def uploaded_video_id_from(string)
        xml = REXML::Document.new(string)
        xml.elements["//id"].text[/videos\/(.+)/, 1]
      end

      # If data can be read, use the first 1024 bytes as filename. If data
      # is a file, use path. If data is a string, checksum it
      def generate_uniq_filename_from(data)
        if data.respond_to?(:path)
          Digest::MD5.hexdigest(data.path)
        elsif data.respond_to?(:read)
          chunk = data.read(1024)
          data.rewind
          Digest::MD5.hexdigest(chunk)
        else
          Digest::MD5.hexdigest(data)
        end
      end

      def auth_token
        @auth_token ||= begin
          http = Net::HTTP.new("www.google.com", 443)
          http.use_ssl = true
          body = "Email=#{YouTubeIt.esc @user}&Passwd=#{YouTubeIt.esc @pass}&service=youtube&source=#{YouTubeIt.esc @client_id}"
          response = http.post("/youtube/accounts/ClientLogin", body, "Content-Type" => "application/x-www-form-urlencoded")
          raise UploadError, response.body[/Error=(.+)/,1] if response.code.to_i != 200
          @auth_token = response.body[/Auth=(.+)/, 1]
        end
      end

      # TODO: isn't there a cleaner way to output top-notch XML without requiring stuff all over the place?
      def video_xml
        b = Builder::XmlMarkup.new
        b.instruct!
        b.entry(:xmlns => "http://www.w3.org/2005/Atom", 'xmlns:media' => "http://search.yahoo.com/mrss/", 'xmlns:yt' => "http://gdata.youtube.com/schemas/2007") do | m |
          m.tag!("media:group") do | mg |
            mg.tag!("media:title", @opts[:title], :type => "plain")
            mg.tag!("media:description", @opts[:description], :type => "plain")
            mg.tag!("media:keywords", @opts[:keywords].join(","))
            mg.tag!('media:category', @opts[:category], :scheme => "http://gdata.youtube.com/schemas/2007/categories.cat")
            mg.tag!('yt:private') if @opts[:private]
          end
          m.tag!("yt:accessControl", :action => "rate", :permission => @opts[:rate]) if @opts[:rate]
          m.tag!("yt:accessControl", :action => "comment", :permission => @opts[:comment]) if @opts[:comment]
          m.tag!("yt:accessControl", :action => "commentVote", :permission => @opts[:commentVote]) if @opts[:commentVote]
          m.tag!("yt:accessControl", :action => "videoRespond", :permission => @opts[:videoRespond]) if @opts[:videoRespond]
          m.tag!("yt:accessControl", :action => "list", :permission => @opts[:list]) if @opts[:list]
          m.tag!("yt:accessControl", :action => "embed", :permission => @opts[:embed]) if @opts[:embed]
          m.tag!("yt:accessControl", :action => "syndicate", :permission => @opts[:syndicate]) if @opts[:syndicate]
        end.to_s
      end

      def generate_upload_io(video_xml, data)
        post_body = [
          "--#{boundary}\r\n",
          "Content-Type: application/atom+xml; charset=UTF-8\r\n\r\n",
          video_xml,
          "\r\n--#{boundary}\r\n",
          "Content-Type: #{@opts[:mime_type]}\r\nContent-Transfer-Encoding: binary\r\n\r\n",
          data,
          "\r\n--#{boundary}--\r\n",
        ]

        # Use Greedy IO to not be limited by 1K chunks
        YouTubeIt::GreedyChainIO.new(post_body)
      end

    end
  end
end

