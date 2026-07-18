require "active_support/all"
require 'nokogiri'
require 'open-uri'
require 'fileutils'
require 'yaml'

module Helpers
  extend ActiveSupport::NumberHelper
end

module Jekyll
  class GoogleScholarCitationsTag < Liquid::Tag
    Citations = { }
    CACHE_RELATIVE_PATH = File.join("_data", "google_scholar_citations.yml")
    REQUEST_HEADERS = {
      "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
      "Accept-Language" => "en-US,en;q=0.9"
    }.freeze

    def initialize(tag_name, params, tokens)
      super
      splitted = params.split(" ").map(&:strip)
      @scholar_id = splitted[0]
      @article_id = splitted[1]
    end

    def render(context)
      article_id = context[@article_id.strip].to_s
      scholar_id = context[@scholar_id.strip].to_s
      site = context.registers[:site]

      # If the citation count has already been fetched during this build, return it.
      if GoogleScholarCitationsTag::Citations[article_id]
        return GoogleScholarCitationsTag::Citations[article_id]
      end

      begin
        citation_count = fetch_citation_count(scholar_id, article_id)
        save_cached_citation_count(site, article_id, citation_count)
      rescue StandardError => e
        citation_count = cached_citation_count(site, article_id)

        if citation_count.nil?
          citation_count = "N/A"
          log_warning("No cached citation count for #{article_id}; using N/A after #{e.class} - #{e.message}")
        else
          log_warning("Using cached citation count for #{article_id} after #{e.class} - #{e.message}")
        end
      end

      citation_count = format_citation_count(citation_count)
      GoogleScholarCitationsTag::Citations[article_id] = citation_count
      return "#{citation_count}"
    end

    private

    def fetch_citation_count(scholar_id, article_id)
      article_url = "https://scholar.google.com/citations?view_op=view_citation&hl=en&user=#{scholar_id}&citation_for_view=#{scholar_id}:#{article_id}"

      # Sleep for a random amount of time to reduce the chance of being blocked.
      sleep(rand(1.5..3.5))

      doc = Nokogiri::HTML(
        URI.open(
          article_url,
          REQUEST_HEADERS.merge(
            :open_timeout => 10,
            :read_timeout => 10
          )
        )
      )

      cited_by_text = [
        doc.at_css('meta[name="description"]')&.[]('content'),
        doc.at_css('meta[property="og:description"]')&.[]('content')
      ].compact.find { |content| content.match?(/Cited by (\d+[,\d]*)/) }

      raise "Could not parse citation count from Google Scholar response" if cited_by_text.nil?

      cited_by_text.match(/Cited by (\d+[,\d]*)/)[1].delete(",").to_i
    end

    def format_citation_count(citation_count)
      return citation_count if citation_count == "N/A"

      Helpers.number_to_human(
        citation_count.to_i,
        :format => '%n%u',
        :precision => 2,
        :units => { :thousand => 'K', :million => 'M', :billion => 'B' }
      )
    end

    def cached_citation_count(site, article_id)
      citation_cache(site)[article_id]
    end

    def citation_cache(site)
      @citation_cache ||= begin
        cache_path = citation_cache_path(site)
        if File.exist?(cache_path)
          data = YAML.safe_load(File.read(cache_path)) || {}
          data.is_a?(Hash) ? data : {}
        else
          {}
        end
      rescue Psych::SyntaxError => e
        log_warning("Could not read citation cache: #{e.message}")
        {}
      end
    end

    def save_cached_citation_count(site, article_id, citation_count)
      cache = citation_cache(site)
      return if cache[article_id] == citation_count

      cache[article_id] = citation_count
      cache_path = citation_cache_path(site)
      FileUtils.mkdir_p(File.dirname(cache_path))
      File.write(cache_path, cache.sort.to_h.to_yaml)
    rescue StandardError => e
      log_warning("Could not write citation cache for #{article_id}: #{e.class} - #{e.message}")
    end

    def citation_cache_path(site)
      File.join(site.source, CACHE_RELATIVE_PATH)
    end

    def log_warning(message)
      Jekyll.logger.warn "Google Scholar:", message
    rescue ArgumentError
      Jekyll.logger.warn "Google Scholar: #{message}"
    end
  end
end

Liquid::Template.register_tag('google_scholar_citations', Jekyll::GoogleScholarCitationsTag)
