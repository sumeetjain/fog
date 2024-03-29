require 'fog/core/model'
require 'fog/aws/models/storage/versions'

module Fog
  module Storage
    class AWS

      class File < Fog::Model

        identity  :key,             :aliases => 'Key'

        attr_writer :body
        attribute :cache_control,       :aliases => 'Cache-Control'
        attribute :content_disposition, :aliases => 'Content-Disposition'
        attribute :content_encoding,    :aliases => 'Content-Encoding'
        attribute :content_length,      :aliases => ['Content-Length', 'Size'], :type => :integer
        attribute :content_md5,         :aliases => 'Content-MD5'
        attribute :content_type,        :aliases => 'Content-Type'
        attribute :etag,                :aliases => ['Etag', 'ETag']
        attribute :expires,             :aliases => 'Expires'
        attribute :last_modified,       :aliases => ['Last-Modified', 'LastModified']
        attribute :metadata
        attribute :owner,               :aliases => 'Owner'
        attribute :storage_class,       :aliases => ['x-amz-storage-class', 'StorageClass']
        attribute :encryption,          :aliases => 'x-amz-server-side-encryption'
        attribute :version,             :aliases => 'x-amz-version-id'

        # Chunk size to use for multipart uploads
        # Use small chunk sizes to minimize memory
        # E.g. 5242880 = 5mb
        attr_accessor :multipart_chunk_size

        def acl=(new_acl)
          valid_acls = ['private', 'public-read', 'public-read-write', 'authenticated-read']
          unless valid_acls.include?(new_acl)
            raise ArgumentError.new("acl must be one of [#{valid_acls.join(', ')}]")
          end
          @acl = new_acl
        end

        def body
          attributes[:body] ||= if last_modified && (file = collection.get(identity))
            file.body
          else
            ''
          end
        end

        def body=(new_body)
          attributes[:body] = new_body
        end

        def directory
          @directory
        end

        def copy(target_directory_key, target_file_key, options = {})
          requires :directory, :key
          connection.copy_object(directory.key, key, target_directory_key, target_file_key, options)
          target_directory = connection.directories.new(:key => target_directory_key)
          target_directory.files.head(target_file_key)
        end

        def destroy(options = {})
          requires :directory, :key
          attributes[:body] = nil if options['versionId'] == version
          connection.delete_object(directory.key, key, options)
          true
        end

        remove_method :metadata
        def metadata
          attributes.reject {|key, value| !(key.to_s =~ /^x-amz-meta-/)}
        end

        remove_method :metadata=
        def metadata=(new_metadata)
          merge_attributes(new_metadata)
        end

        remove_method :owner=
        def owner=(new_owner)
          if new_owner
            attributes[:owner] = {
              :display_name => new_owner['DisplayName'],
              :id           => new_owner['ID']
            }
          end
        end

        def public=(new_public)
					puts "\n\nnew_public is #{new_public}\n\n"
          if new_public
            @acl = 'public-read'
          else
            @acl = 'private'
          end
          new_public
        end

        def public_url
          requires :directory, :key
          if connection.get_object_acl(directory.key, key).body['AccessControlList'].detect {|grant| grant['Grantee']['URI'] == 'http://acs.amazonaws.com/groups/global/AllUsers' && grant['Permission'] == 'READ'}
            if directory.key.to_s =~ /^(?:[a-z]|\d(?!\d{0,2}(?:\.\d{1,3}){3}$))(?:[a-z0-9]|\-(?![\.])){1,61}[a-z0-9]$/
              "https://#{directory.key}.s3.amazonaws.com/#{Fog::AWS.escape(key)}"
            else
              "https://s3.amazonaws.com/#{directory.key}/#{Fog::AWS.escape(key)}"
            end
          else
            nil
          end
        end

        def save(options = {})
          requires :body, :directory, :key
          if options != {}
            Fog::Logger.deprecation("options param is deprecated, use acl= instead [light_black](#{caller.first})[/]")
          end
          options['x-amz-acl'] ||= @acl if @acl
          options['Cache-Control'] = cache_control if cache_control
          options['Content-Disposition'] = content_disposition if content_disposition
          options['Content-Encoding'] = content_encoding if content_encoding
          options['Content-MD5'] = content_md5 if content_md5
          options['Content-Type'] = content_type if content_type
          options['Expires'] = expires if expires
          options.merge!(metadata)
          options['x-amz-storage-class'] = storage_class if storage_class
          options['x-amz-server-side-encryption'] = encryption if encryption

					puts "\n\nacl is #{@acl} and options are: #{options.inspect}\n\n"

          if multipart_chunk_size && body.respond_to?(:read)
            data = multipart_save(options)
            merge_attributes(data.body)
          else
            data = connection.put_object(directory.key, key, body, options)
            merge_attributes(data.headers.reject {|key, value| ['Content-Length', 'Content-Type'].include?(key)})
          end
          self.etag.gsub!('"','')
          self.content_length = Fog::Storage.get_body_size(body)
          self.content_type ||= Fog::Storage.get_content_type(body)
          true
        end

        def url(expires, options = {})
          requires :key
          collection.get_url(key, expires, options)
        end

        def versions
          @versions ||= begin
            Fog::Storage::AWS::Versions.new(
              :file         => self,
              :connection   => connection
            )
          end
        end

        private

        def directory=(new_directory)
          @directory = new_directory
        end

        def multipart_save(options)
          # Initiate the upload
          res = connection.initiate_multipart_upload(directory.key, key, options)
          upload_id = res.body["UploadId"]

          # Store ETags of upload parts
          part_tags = []

          # Upload each part
          # TODO: optionally upload chunks in parallel using threads
          # (may cause network performance problems with many small chunks)
          # TODO: Support large chunk sizes without reading the chunk into memory
          body.rewind if body.respond_to?(:rewind)
          while (chunk = body.read(multipart_chunk_size)) do
            part_upload = connection.upload_part(directory.key, key, upload_id, part_tags.size + 1, chunk )
            part_tags << part_upload.headers["ETag"]
          end

        rescue
          # Abort the upload & reraise
          connection.abort_multipart_upload(directory.key, key, upload_id) if upload_id
          raise
        else
          # Complete the upload
          connection.complete_multipart_upload(directory.key, key, upload_id, part_tags)
        end

      end

    end
  end
end
