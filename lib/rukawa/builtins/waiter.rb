require 'rukawa/builtins/base'
require 'timeout'

module Rukawa
  module Builtins
    class Waiter < Base
      class_attribute :timeout, :poll_interval

      self.timeout = 1800
      self.poll_interval = 1

      class << self
        def handle_parameters(timeout: nil, poll_interval: nil, **rest)
          self.timeout = timeout if timeout
          self.poll_interval = poll_interval if poll_interval
        end
      end

      def run
        Timeout.timeout(timeout) do
          wait_until do
            fetch_condition
          end
        end
      end

      private

      def wait_until
        until yield
          sleep poll_interval
        end
      end

      def fetch_condition
        raise NotImplementedError
      end
    end

    class SleepWaiter < Waiter
      class_attribute :sec

      class << self
        def handle_parameters(sec:, **rest)
          self.sec = sec
        end
      end

      private

      def fetch_condition
        sleep sec
      end
    end

    class LocalFileWaiter < Waiter
      class_attribute :path, :if_modified_since, :if_unmodified_since

      class << self
        def handle_parameters(path:, if_modified_since: nil, if_unmodified_since: nil, **rest)
          self.path = path
          self.if_modified_since = if_modified_since if if_modified_since
          self.if_unmodified_since = if_unmodified_since if if_unmodified_since
          super(**rest)
        end
      end

      private

      def fetch_condition
        if path.respond_to?(:all?)
          get_stat_and_check_condition(p)
          path.all?(&method(:get_stat_and_check_condition))
        else
          get_stat_and_check_condition(path)
        end
      end

      def get_stat_and_check_condition(path)
        stat = File.stat(path)

        if if_modified_since
          stat.mtime > if_modified_since
        elsif if_unmodified_since
          stat.mtime <= if_unmodified_since
        else
          true
        end
      rescue
        false
      end
    end

    class S3Waiter < Waiter
      class_attribute :url, :aws_access_key_id, :aws_secret_access_key, :region, :if_modified_since, :if_unmodified_since

      class << self
        def handle_parameters(url:, aws_access_key_id: nil, aws_secret_access_key: nil, region: nil, if_modified_since: nil, if_unmodified_since: nil, **rest)
          require 'aws-sdk'

          self.url = url
          self.aws_access_key_id = aws_access_key_id if aws_access_key_id
          self.aws_secret_access_key = aws_secret_access_key if aws_secret_access_key
          self.region = region if region
          self.if_modified_since = if_modified_since if if_modified_since
          self.if_unmodified_since = if_unmodified_since if if_unmodified_since
          super(**rest)
        end
      end

      private

      def fetch_condition
        opts = {if_modified_since: if_modified_since, if_unmodified_since: if_unmodified_since}.reject do |_, v|
          v.nil?
        end

        if url.respond_to?(:all?)
          url.all? do |u|
            s3url = URI.parse(u)
            client.head_object(bucket: s3url.host, key: s3url.path[1..-1], **opts) rescue false
          end
        else
          s3url = URI.parse(url)
          client.head_object(bucket: s3url.host, key: s3url.path[1..-1], **opts) rescue false
        end
      end

      def client
        return @client if @client

        if aws_secret_access_key || aws_secret_access_key || region
          options = {access_key_id: aws_access_key_id, secret_access_key: aws_secret_access_key, region: region}.reject do |_, v|
            v.nil?
          end
          @client = Aws::S3::Client.new(options)
        else
          @client = Aws::S3::Client.new
        end
      end
    end

    class GCSWaiter < Waiter
      class_attribute :url, :json_key, :if_modified_since, :if_unmodified_since

      class << self
        def handle_parameters(url:, json_key: nil, if_modified_since: nil, if_unmodified_since: nil, **rest)
          require 'google/apis/storage_v1'
          require 'googleauth'

          self.url = url
          self.json_key = json_key if json_key
          self.if_modified_since = if_modified_since if if_modified_since
          self.if_unmodified_since = if_unmodified_since if if_unmodified_since
          super(**rest)
        end
      end

      private

      def fetch_condition
        if url.respond_to?(:all?)
          url.all? do |u|
            get_object_and_check_condition(URI.parse(u))
          end
        else
          get_object_and_check_condition(URI.parse(url))
        end
      end

      def get_object_and_check_condition(url)
        obj = client.get_object(url.host, url.path[1..-1])
        if if_modified_since
          obj.updated.to_time > if_modified_since
        elsif if_unmodified_since
          obj.updated.to_time <= if_unmodified_since
        else
          true
        end
      rescue
        false
      end

      def client
        return @client if @client

        client = Google::Apis::StorageV1::StorageService.new
        scope = "https://www.googleapis.com/auth/devstorage.read_only"

        if json_key
          begin
            JSON.parse(json_key)
            key = StringIO.new(json_key)
            client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: key, scope: scope)
          rescue JSON::ParserError
            key = json_key
            File.open(json_key) do |f|
              client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: f, scope: scope)
            end
          end
        else
          client.authorization = Google::Auth.get_application_default([scope])
        end
        client
      end
    end
  end
end
