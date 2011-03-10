require 'digest/md5'
require 'mime/types'
require 'aws/s3'
require 'time'

module AssetID
  class Base
    DEFAULT_ASSET_PATHS = ['favicon.ico', 'images', 'javascripts', 'stylesheets']
    @@asset_paths = DEFAULT_ASSET_PATHS
    
    def self.path_prefix
      File.join Rails.root, 'public'
    end
    
    def self.asset_paths=(paths)
      @@asset_paths = paths
    end
    
    def self.asset_paths
      @@asset_paths
    end
    
    def self.absolute_path(path)
      File.join path_prefix, path
    end
    
    def self.assets
      asset_paths.inject([]) {|assets, path|
        path = absolute_path(path)
        assets << path if File.exists? path and !File.directory? path
        assets += Dir.glob(path + '/**/*').inject([]) {|m, file| 
          m << file unless File.directory? file; m 
        }
      }
    end
    
    def self.fingerprint(path)
      path = File.join path_prefix, path unless path =~ /#{path_prefix}/
      d = Digest::MD5.hexdigest(File.read(path))
      path = path.gsub(path_prefix, '')
      File.join File.dirname(path), "#{File.basename(path, File.extname(path))}-id-#{d}#{File.extname(path)}"
    end
  end
  
  class S3 < AssetID::Base
    DEFAULT_GZIP_TYPES = ['text/css', 'application/javascript']
    @@gzip_types = DEFAULT_GZIP_TYPES
    
    def self.gzip_types=(types)
      @@gzip_types = types
    end
    
    def self.gzip_types
      @@gzip_types
    end
    
    def self.s3_config
      @@config ||= YAML.load_file(File.join(Rails.root, "config/asset_id.yml"))[Rails.env] rescue nil || {}
    end
    
    def self.connect_to_s3
      AWS::S3::Base.establish_connection!(
        :access_key_id => s3_config['access_key_id'],
        :secret_access_key => s3_config['secret_access_key']
      )
    end
    
    def self.cache_headers
      {
        'Cache-Control' => 'max-age=315360000',
        'Expires' => (Time.now + (10 * 60 * 60 * 24 * 365)).httpdate,
      }
    end
    
    def self.gzip_headers
      {
        'Content-Encoding' => 'gzip', 
        'Vary' => 'Accept-Encoding'
      }
    end
    
    def self.s3_permissions
      :public_read
    end
    
    def self.s3_bucket
      s3_config['bucket']
    end
    
    def self.fingerprint(path)
      #File.join "/#{self.s3_bucket}", fingerprint(path)
      super(path)
    end
    
    def self.upload(options={})
      connect_to_s3
      assets.each do |asset|
        # debug
        puts "asset_id: Uploading #{asset} as #{fingerprint(asset)}" if options[:debug]
        
        # grab mime type
        mime_type = MIME::Types.of(asset).first.to_s
        
        # merge headers
        headers = {
          :content_type => mime_type,
          :access => s3_permissions,
        }.merge(cache_headers)
        
        # load data
        data = File.read(asset)
        
        # replace css urls
        if mime_type == 'text/css'
          data.gsub!(/(\.{0,2}\/?images\/[^"'\)]+)/i) do |path|
            fingerprint(path.gsub!(/^\.{0,2}\/?/, '').gsub!(/\?\d+$/, ''))
          end
        end
        
        # # gzip content
        # if gzip_types.include? mime_type
        #   data = Zlib::Deflate.deflate(data)
        #   headers.merge!(gzip_headers)
        # end
        
        # store object
        AWS::S3::S3Object.store(fingerprint(asset), data, s3_bucket, headers) unless options[:dry_run]
      end
    end
  end
end
