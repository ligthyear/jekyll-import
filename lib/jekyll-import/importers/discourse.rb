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
          puts categories
          categories
        end

        def self.process_topics(url)
          topic_list = self.fetch(url)["topic_list"]
          topic_list["topics"].each { |t| self.process_topic(t) }
          # self.process_topics(topic_list["more_topics_url"]) if topic_list["more_topics_url"].present?
        end

        def self.process_topic(topic)
          id = topic["id"]
          title = topic["fancy_title"] || topic["title"]
          category_id = topic["category_id"]
          slug = topic["slug"]

          puts "Found #{id} #{title} (#{slug}, #{category_id})"

          created_at = topic["created_at"]
          category =  @categories[category_id]["name"]
          image_url = topic["image_url"]

          raw_post = self.get_raw_post(topic)
          image_url = self.load_image(image_url, slug) if !image_url.nil? && @download_images

        end

        def self.get_raw_post(topic)
          topic_id = topic["id"]
          post_stream = fetch(@base + "t/#{topic_id}/1.json")["post_stream"]["stream"]
          post = fetch(@base + "posts/#{post_stream.first}.json")
          return post["raw"] if !@download_images

          # using the same processing "technique" as discourse: nokogiri
          # on the cooked data
          raw = post["raw"].dup
          doc = Nokogiri::HTML::fragment(post["cooked"])
          cooked = doc.css("img[src]") - doc.css(".onebox-result img") - doc.css("img.avatar")
          cooked.each do |image|
            src = image['src']
            src = "http:" + src if src.start_with?("//")

            url = self.load_image(src, topic["slug"])
            escaped_src = Regexp.escape(src)
            # there are 6 ways to insert an image in a post
            # HTML tag - <img src="http://...">
            raw.gsub!(/src=["']#{escaped_src}["']/i, "src='#{url}'")
            # BBCode tag - [img]http://...[/img]
            raw.gsub!(/\[img\]#{escaped_src}\[\/img\]/i, "[img]#{url}[/img]")
            # Markdown linked image - [![alt](http://...)](http://...)
            raw.gsub!(/\[!\[([^\]]*)\]\(#{escaped_src}\)\]/) { "[<img src='#{url}' alt='#{$1}'>]" }
            # Markdown inline - ![alt](http://...)
            raw.gsub!(/!\[([^\]]*)\]\(#{escaped_src}\)/) { "![#{$1}](#{url})" }
            # Markdown reference - [x]: http://
            raw.gsub!(/\[(\d+)\]: #{escaped_src}/) { "[#{$1}]: #{url}" }
            # Direct link
            raw.gsub!(src, "<img src='#{url}'>")
          end
          raw
        end

        def self.load_image(url, prefix='')
          filename = File.join(@assets, prefix + File.basename(URI.parse(url).path))
          return filename if File.exists? filename

          FileUtils.mkdir_p(File.dirname(filename)) if !File.exists? File.dirname(filename)

          open(url) {|f|
             File.open(filename, "wb") do |file|
               IO.copy_stream(f, file)
             end
          }
          filename
        end

        def self.fetch(url)
          content = ""
          open(url) { |s| content = JSON.load(s) }
          content
        end
    end
  end
end

