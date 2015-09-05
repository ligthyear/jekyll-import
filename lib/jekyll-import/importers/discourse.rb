module JekyllImport
  module Importers
    class Discourse < Importer
      def self.specify_options(c)
        c.option 'base', '--base URL', 'The http(s) url to the discourse instance (e.g. https://meta.discourse.org/ )'
        c.option 'assets', '--assets PATH', 'local path to store all downloaded images at'
        c.option 'no-redirects', '--no-redirects', 'Disable generation of redirect_from-style tags in the header of posts'
        c.option 'no-image-download', 'no-image-download', 'Disable downloading of images, use remote paths found'
      end

      def self.validate(options)
        if options['base'].nil?
          abort "Missing mandatory option --base."
        end
      end

      def self.require_deps
        JekyllImport.require_with_fallback(%w[
          open-uri
          fileutils
          json
          nokogiri
          date
        ])
      end

      # Process the import.
      #
      # base - a URL to the discourse instance
      #
      # Returns nothing.
      def self.process(options)

        FileUtils.mkdir_p("_posts")
        @base = options.fetch('base')
        @base += "/" if @base[-1] != "/"

        @assets = options['assets'] || "assets"
        FileUtils.mkdir_p(@assets)

        @download_images = options["no-image-download"].nil?
        @add_redirects = options["no-redirects"].nil?

        @categories = self.get_categories

        self.process_topics(@base + "/latest.json?no_definitions=true")
        puts "Done!"
      end


      private

        def self.get_categories
          categories = {}

          self.fetch(@base + "categories.json")["category_list"]["categories"].each do |c|
            category_id = c['id']
            categories[category_id] = c["name"]
            if !c["subcategory_ids"].nil?
              self.fetch(@base + "categories.json?parent_category_id=#{category_id}")["category_list"]["categories"].each do |sc|
                categories[sc['id']] = c["name"] + "/" + sc["name"]
              end
            end
          end
          categories
        end

        def self.process_topics(url)
          topic_list = self.fetch(url)["topic_list"]
          topic_list["topics"].each { |t| self.process_topic(t) }
          self.process_topics(@base + topic_list["more_topics_url"]) if !topic_list["more_topics_url"].nil?
        end

        def self.process_topic(topic)
          id = topic["id"]
          title = topic["fancy_title"] || topic["title"]
          category_id = topic["category_id"]
          slug = topic["slug"]

          puts "Found #{id} #{title} (#{slug}, #{category_id})"

          created_at = topic["created_at"]
          formatted_date = DateTime.parse(created_at).strftime('%Y-%m-%d')
          category =  @categories[category_id]
          image_url = topic["image_url"]

          raw_post = self.get_raw_post(topic)
          image_url = self.load_image(image_url, slug) if !image_url.nil? && @download_images

          header = {
            'layout' => 'post',
            'title' => title,
            'date' => created_at,
            "category" => category.split("/")
          }

          header["image"] = image_url if !image_url.nil?

          header["redirects"] = [
            "/t/#{id}",
            "/t/#{id}/",
            "/t/#{id}/1",
            "/t/#{id}/#{slug}",
            "/t/#{id}/#{slug}/1",
            "/t/#{slug}",
            "/t/#{slug}/1",
          ] if @add_redirects

          File.open("_posts/#{formatted_date}-#{slug}.html", "w") do |f|
            f.puts header.to_yaml
            f.puts "---\n\n"
            f.puts raw_post
          end

        end

        def self.get_raw_post(topic)
          topic_id = topic["id"]
          post_stream = fetch(@base + "t/#{topic_id}/1.json")["post_stream"]["stream"]
          post = fetch(@base + "posts/#{post_stream.first}.json")
          return post["raw"] if !@download_images

          raw = post["raw"].dup
          prefix = topic["slug"] + "-"

          raw.gsub!(/(\<img[^\>]*)src=["'](.+?)["']/i) do |x|
            url = self.load_image($2, prefix)
            "#{$1}src='#{url}'"
          end
          # BBCode tag - [img]http://...[/img]
          raw.gsub!(/\[img\](.*)\[\/img\]/i) do |x|
            url = self.load_image($1, prefix)
            "[img]#{url}[/img]"
          end
          # Markdown linked image - [![alt](http://...)](http://...)
          raw.gsub!(/\[!\[([^\]]*)\]\((.*)\)\]/) do |x|
            url = self.load_image($2, prefix)
            "[<img src='#{url}' alt='#{$1}'>]"
          end
          # Markdown inline - ![alt](http://...)
          raw.gsub!(/!\[([^\]]*)\]\((.*)\)/) do |x|
            url = self.load_image($2, prefix)
            "![#{$1}](#{url})"
          end
          # Markdown reference - [x]: http://
          raw.gsub!(/\[(\d+)\]: (.*)$/) do |x|
            url = self.load_image($2, prefix)
            "[#{$1}]: #{url}"
          end

          raw
        end

        def self.load_image(url, prefix='')

          if url.start_with?("//")
            url = "http:" + url
          elsif url.start_with?("/")
            url = @base + url
          end

          filename = File.join(@assets, prefix + File.basename(URI.parse(url).path))
          return "/#{filename}" if File.exists? filename

          FileUtils.mkdir_p(File.dirname(filename)) if !File.exists? File.dirname(filename)
          begin
            open(url) {|f|
               File.open(filename, "wb") do |file|
                 IO.copy_stream(f, file)
               end
            }
          rescue OpenURI::HTTPError
            return url
          end
          "/#{filename}"
        end

        def self.fetch(url)
          content = ""
          open(url) { |s| content = JSON.load(s) }
          content
        end
    end
  end
end

