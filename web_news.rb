#!/usr/bin/env ruby
require 'sinatra'
require 'rss'
require 'open-uri'
require 'sqlite3'
require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'

# NewsAggregator class with image downloading and category detection
class NewsAggregator
  attr_reader :db
  
  UNSPLASH_ACCESS_KEY = ENV['UNSPLASH_ACCESS_KEY'] || 'YOUR_KEY_HERE'
  
  # Category colors for pills
  CATEGORY_COLORS = {
    'Technology' => '#667eea',
    'Business' => '#f59e0b',
    'Politics' => '#ef4444',
    'Science' => '#10b981',
    'Sports' => '#3b82f6',
    'Entertainment' => '#ec4899',
    'World' => '#8b5cf6',
    'Health' => '#06b6d4',
    'General' => '#6b7280'
  }
  
  CATEGORIES = {
    'Technology' => %w(tech ai software app apple google microsoft bitcoin crypto computer data code programming algorithm),
    'Business' => %w(business economy market stock finance company startup ceo trade investment bank),
    'Politics' => %w(politics election government congress senate president minister parliament vote law),
    'Science' => %w(science research study climate space nasa brain health medical doctor),
    'Sports' => %w(football soccer basketball baseball tennis cricket sports game player team match),
    'Entertainment' => %w(movie film music celebrity actor actress netflix spotify concert album show),
    'World' => %w(china russia ukraine israel iran india europe asia africa australia war),
    'Health' => %w(covid vaccine health hospital doctor medical disease drug treatment patient)
  }

  def initialize(db_path = 'news.db')
    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    setup_database
    FileUtils.mkdir_p('public/images/articles')
  end

  def setup_database
    @db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS articles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        link TEXT UNIQUE NOT NULL,
        description TEXT,
        pub_date TEXT,
        source TEXT,
        category TEXT,
        image_url TEXT,
        local_image TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    SQL
    
    begin
      @db.execute("SELECT category FROM articles LIMIT 1")
    rescue SQLite3::SQLException
      @db.execute("ALTER TABLE articles ADD COLUMN category TEXT")
    end
  end

  def detect_category(title, description)
    text = "#{title} #{description}".downcase
    
    scores = {}
    CATEGORIES.each do |category, keywords|
      score = keywords.count { |keyword| text.include?(keyword) }
      scores[category] = score if score > 0
    end
    
    scores.empty? ? 'General' : scores.max_by { |_, score| score }[0]
  end

  def get_category_color(category)
    CATEGORY_COLORS[category] || CATEGORY_COLORS['General']
  end

  def extract_keywords(title)
    stopwords = %w(the a an and or but in on at to for of with from by about as into
                   through after before between under over above below up down out off
                   this that these those is are was were be been being have has had
                   do does did will would could should may might can must shall)
    
    words = title.downcase
                 .gsub(/[^\w\s]/, ' ')
                 .split
                 .reject { |w| stopwords.include?(w) || w.length < 3 }
    
    keywords = words.take(3).join(' ')
    keywords.empty? ? title.split.take(2).join(' ') : keywords
  end

  def download_image(url, article_id)
    return nil unless url && url.to_s.start_with?('http')
    
    begin
      parsed_uri = URI.parse(url)
      path = parsed_uri.path || ''
      ext = File.extname(path).split('?').first
      ext = '.jpg' if ext.nil? || ext.empty? || ext.length > 5
      filename = "article_#{article_id}_#{Digest::MD5.hexdigest(url.to_s)}#{ext}"
      filepath = "public/images/articles/#{filename}"
      
      unless File.exist?(filepath)
        URI.open(url, 'rb', redirect: true, read_timeout: 10) do |image|
          File.open(filepath, 'wb') do |file|
            file.write(image.read)
          end
        end
      end
      
      return "/images/articles/#{filename}"
    rescue => e
      puts "  ⚠️  Failed to download image: #{e.message}"
      return nil
    end
  end

  def fetch_unsplash_image(keywords, article_id)
    if UNSPLASH_ACCESS_KEY != 'YOUR_KEY_HERE'
      begin
        query = URI.encode_www_form_component(keywords)
        url = "https://api.unsplash.com/search/photos?query=#{query}&per_page=1&orientation=landscape"
        
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        request['Authorization'] = "Client-ID #{UNSPLASH_ACCESS_KEY}"
        
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 10) do |http|
          http.request(request)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          if data['results'] && data['results'].length > 0
            image_url = data['results'][0]['urls']['regular']
            return download_image(image_url, article_id)
          end
        end
      rescue => e
        puts "  ⚠️  Unsplash fetch failed: #{e.message}"
      end
    end
    
    begin
      seed = Digest::MD5.hexdigest(keywords)[0..6]
      picsum_url = "https://picsum.photos/seed/#{seed}/800/450"
      return download_image(picsum_url, article_id)
    rescue => e
      puts "  ⚠️  Picsum fetch failed: #{e.message}"
    end
    
    nil
  end

  def extract_image(item)
    if item.respond_to?(:enclosure) && item.enclosure && item.enclosure.url
      return item.enclosure.url if item.enclosure.type&.include?('image')
    end
    
    if item.respond_to?(:itunes_image) && item.itunes_image
      return item.itunes_image.href
    end
    
    if item.respond_to?(:media_content) && item.media_content
      return item.media_content.url
    end
    
    if item.respond_to?(:media_thumbnail) && item.media_thumbnail
      return item.media_thumbnail.url
    end
    
    content = item.description || item.content_encoded rescue nil
    if content
      match = content.match(/<img[^>]+src=["']([^"']+)["']/i)
      return match[1] if match
      
      match = content.match(/og:image["']?\s+content=["']([^"']+)["']/i)
      return match[1] if match
    end
    
    if item.respond_to?(:content_encoded) && item.content_encoded
      match = item.content_encoded.match(/<img[^>]+src=["']([^"']+)["']/i)
      return match[1] if match
    end
    
    nil
  end

  def get_item_description(item)
    if item.respond_to?(:description) && item.description
      return item.description
    elsif item.respond_to?(:summary) && item.summary
      return item.summary.content rescue item.summary
    elsif item.respond_to?(:content) && item.content
      return item.content.content rescue item.content
    end
    nil
  end

  def get_item_title(item)
    if item.respond_to?(:title)
      title = item.title
      return title.content if title.respond_to?(:content)
      return title
    end
    'Untitled'
  end

  def get_item_link(item)
    if item.respond_to?(:link)
      link = item.link
      return link.href if link.respond_to?(:href)
      return link
    end
    nil
  end

  def get_item_date(item)
    if item.respond_to?(:pubDate) && item.pubDate
      return item.pubDate.to_s
    elsif item.respond_to?(:published) && item.published
      return item.published.to_s
    elsif item.respond_to?(:updated) && item.updated
      return item.updated.to_s
    end
    Time.now.to_s
  end

  def fetch_feed(url, source_name)
    begin
      URI.open(url) do |rss|
        feed = RSS::Parser.parse(rss)
        articles_added = 0
        
        feed.items.each do |item|
          begin
            title = get_item_title(item)
            link = get_item_link(item)
            description = get_item_description(item)
            pub_date = get_item_date(item)
            
            next unless link
            
            image_url = extract_image(item)
            category = detect_category(title, description || '')
            
            @db.execute(
              "INSERT INTO articles (title, link, description, pub_date, source, category, image_url) VALUES (?, ?, ?, ?, ?, ?, ?)",
              [title, link, description, pub_date, source_name, category, image_url]
            )
            
            article_id = @db.last_insert_row_id
            local_image = nil
            
            if image_url
              local_image = download_image(image_url, article_id)
            end
            
            if !local_image
              keywords = extract_keywords(title)
              
              priority_sources = ['BBC News', 'TechCrunch', 'The Verge', 'Reuters', 'The Guardian']
              use_unsplash = priority_sources.include?(source_name)
              
              if use_unsplash
                local_image = fetch_unsplash_image(keywords, article_id)
              else
                seed = Digest::MD5.hexdigest(keywords)[0..6]
                picsum_url = "https://picsum.photos/seed/#{seed}/800/450"
                local_image = download_image(picsum_url, article_id)
              end
            end
            
            if local_image
              @db.execute("UPDATE articles SET local_image = ? WHERE id = ?", [local_image, article_id])
            end
            
            articles_added += 1
          rescue SQLite3::ConstraintException
          rescue => e
            puts "  ❌ Error processing article: #{e.message}"
          end
        end
        
        return articles_added
      end
    rescue => e
      puts "Error fetching #{source_name}: #{e.message}"
      return 0
    end
  end

  def fetch_all_feeds
    feeds = {
      'BBC News' => 'http://feeds.bbci.co.uk/news/rss.xml',
      'The Guardian' => 'https://www.theguardian.com/world/rss',
      'NPR' => 'https://feeds.npr.org/1001/rss.xml',
      'Al Jazeera' => 'https://www.aljazeera.com/xml/rss/all.xml',
      'TechCrunch' => 'https://techcrunch.com/feed/',
      'Hacker News' => 'https://hnrss.org/frontpage',
      'The Verge' => 'https://www.theverge.com/rss/index.xml',
      'Ars Technica' => 'https://feeds.arstechnica.com/arstechnica/index',
      'Wired' => 'https://www.wired.com/feed/rss',
      'Bloomberg' => 'https://feeds.bloomberg.com/markets/news.rss',
      'Scientific American' => 'http://rss.sciam.com/ScientificAmerican-Global',
      'Nature' => 'https://www.nature.com/nature.rss',
      'Variety' => 'https://variety.com/feed/'
    }

    total_added = 0
    feeds.each { |name, url| total_added += fetch_feed(url, name) }
    total_added
  end

  def get_articles(limit = 50, offset = 0, source = nil, category = nil)
    if source && !source.empty? && category && !category.empty?
      @db.execute(
        "SELECT * FROM articles WHERE source = ? AND category = ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
        [source, category, limit, offset]
      )
    elsif source && !source.empty?
      @db.execute(
        "SELECT * FROM articles WHERE source = ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
        [source, limit, offset]
      )
    elsif category && !category.empty?
      @db.execute(
        "SELECT * FROM articles WHERE category = ? ORDER BY created_at DESC LIMIT ? OFFSET ?",
        [category, limit, offset]
      )
    else
      @db.execute(
        "SELECT * FROM articles ORDER BY created_at DESC LIMIT ? OFFSET ?",
        [limit, offset]
      )
    end
  end

  def search_articles(query)
    @db.execute(
      "SELECT * FROM articles WHERE title LIKE ? OR description LIKE ? ORDER BY created_at DESC LIMIT 100",
      ["%#{query}%", "%#{query}%"]
    )
  end

  def get_sources
    @db.execute("SELECT DISTINCT source FROM articles ORDER BY source")
  end

  def get_categories
    @db.execute("SELECT DISTINCT category FROM articles WHERE category IS NOT NULL ORDER BY category")
  end

  def get_stats
    {
      total: @db.execute("SELECT COUNT(*) as count FROM articles")[0]['count'],
      by_source: @db.execute("SELECT source, COUNT(*) as count FROM articles GROUP BY source ORDER BY count DESC"),
      by_category: @db.execute("SELECT category, COUNT(*) as count FROM articles GROUP BY category ORDER BY count DESC")
    }
  end

  def close
    @db.close
  end
end

# Background refresh thread
Thread.new do
  loop do
    sleep 900
    begin
      aggregator = NewsAggregator.new
      puts "\n🔄 Auto-refreshing feeds at #{Time.now}"
      new_articles = aggregator.fetch_all_feeds
      puts "✅ Auto-refresh complete: #{new_articles} new articles\n"
      aggregator.close
    rescue => e
      puts "❌ Auto-refresh failed: #{e.message}"
    end
  end
end

set :port, 4567
set :bind, '0.0.0.0'
set :public_folder, File.dirname(__FILE__) + '/public'
enable :static

helpers do
  def aggregator
    @aggregator ||= NewsAggregator.new
  end
  
  def truncate_text(text, length = 150)
    return '' unless text
    clean_text = text.gsub(/<[^>]*>/, '').strip
    clean_text.length > length ? clean_text[0...length] + '...' : clean_text
  end
  
  def category_color(category)
    aggregator.get_category_color(category)
  end
end

get '/' do
  @page = (params[:page] || 1).to_i
  @per_page = 20
  @offset = (@page - 1) * @per_page
  @source = params[:source]
  @category = params[:category]
  
  @articles = aggregator.get_articles(@per_page, @offset, @source, @category)
  @sources = aggregator.get_sources
  @categories = aggregator.get_categories
  @stats = aggregator.get_stats
  
  erb :index
end

get '/search' do
  @query = params[:q]
  @articles = @query ? aggregator.search_articles(@query) : []
  @sources = aggregator.get_sources
  @categories = aggregator.get_categories
  @stats = aggregator.get_stats
  
  erb :search
end

post '/refresh' do
  new_articles = aggregator.fetch_all_feeds
  redirect '/?refreshed=true&new=' + new_articles.to_s
end

get '/stats' do
  @stats = aggregator.get_stats
  erb :stats
end

__END__

@@layout
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>News-ish - News Aggregator</title>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    :root {
      --bg-primary: #ffffff;
      --bg-secondary: #f8f9fa;
      --text-primary: #1a1a1a;
      --text-secondary: #6c757d;
      --text-muted: #adb5bd;
      --border-color: #e9ecef;
      --accent-color: #0066cc;
      --card-shadow: 0 2px 8px rgba(0,0,0,0.08);
      --card-shadow-hover: 0 4px 16px rgba(0,0,0,0.12);
    }
    
    [data-theme="dark"] {
      --bg-primary: #121212;
      --bg-secondary: #1e1e1e;
      --text-primary: #e4e4e4;
      --text-secondary: #a0a0a0;
      --text-muted: #6c6c6c;
      --border-color: #2a2a2a;
      --accent-color: #4d9fff;
      --card-shadow: 0 2px 8px rgba(0,0,0,0.4);
      --card-shadow-hover: 0 4px 16px rgba(0,0,0,0.6);
    }
    
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', Roboto, sans-serif;
      background: var(--bg-primary);
      color: var(--text-primary);
      line-height: 1.6;
      transition: background 0.3s, color 0.3s;
      /* Prevent white flash during page transitions */
      min-height: 100vh;
    }
    
    html {
      background: var(--bg-primary);
    }
    
    .header {
      background: var(--bg-primary);
      border-bottom: 1px solid var(--border-color);
      padding: 20px 0;
      position: sticky;
      top: 0;
      z-index: 100;
      backdrop-filter: blur(10px);
    }
    
    .header-content {
      max-width: 1200px;
      margin: 0 auto;
      padding: 0 24px;
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    
    .logo {
      font-size: 1.8em;
      font-weight: 700;
      color: var(--text-primary);
      text-decoration: none;
      letter-spacing: -0.02em;
    }
    
    .header-actions {
      display: flex;
      gap: 16px;
      align-items: center;
    }
    
    .theme-toggle {
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      padding: 10px;
      border-radius: 50%;
      cursor: pointer;
      display: flex;
      transition: transform 0.2s;
    }
    
    .theme-toggle:hover {
      transform: scale(1.1);
    }
    
    .theme-toggle svg {
      width: 20px;
      height: 20px;
      fill: var(--text-primary);
    }
    
    .search-box {
      display: flex;
      gap: 8px;
    }
    
    .search-box input {
      padding: 10px 16px;
      border: 1px solid var(--border-color);
      border-radius: 24px;
      background: var(--bg-secondary);
      color: var(--text-primary);
      font-size: 0.95em;
      min-width: 250px;
    }
    
    .search-box input:focus {
      outline: none;
      border-color: var(--accent-color);
    }
    
    .btn {
      padding: 10px 20px;
      border-radius: 24px;
      border: none;
      cursor: pointer;
      font-weight: 500;
      transition: all 0.2s;
    }
    
    .btn-primary {
      background: var(--accent-color);
      color: white;
    }
    
    .btn-primary:hover {
      transform: translateY(-1px);
      box-shadow: 0 4px 12px rgba(0,102,204,0.3);
    }
    
    .btn-secondary {
      background: var(--bg-secondary);
      color: var(--text-primary);
      border: 1px solid var(--border-color);
    }
    
    .btn-secondary:hover {
      background: var(--border-color);
    }
    
    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 40px 24px;
    }
    
    .section-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 24px;
    }
    
    .section-title {
      font-size: 1.8em;
      font-weight: 700;
      color: var(--text-primary);
    }
    
    .filters {
      display: flex;
      gap: 16px;
      margin-bottom: 32px;
      flex-wrap: wrap;
    }
    
    .filter-select {
      padding: 10px 16px;
      border: 1px solid var(--border-color);
      border-radius: 24px;
      background: var(--bg-secondary);
      color: var(--text-primary);
      cursor: pointer;
      font-size: 0.95em;
    }
    
    .category-pills {
      display: flex;
      gap: 12px;
      margin-bottom: 32px;
      flex-wrap: wrap;
      overflow-x: auto;
      padding-bottom: 8px;
    }
    
    .category-pill {
      padding: 8px 20px;
      border-radius: 24px;
      text-decoration: none;
      font-weight: 500;
      font-size: 0.9em;
      transition: all 0.2s;
      white-space: nowrap;
      color: white;
    }
    
    .category-pill:hover {
      transform: translateY(-2px);
      box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    }
    
    .category-pill.active {
      box-shadow: 0 4px 16px rgba(0,0,0,0.2);
    }
    
    .featured-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
      gap: 24px;
      margin-bottom: 48px;
    }
    
    .featured-card {
      background: var(--bg-secondary);
      border-radius: 16px;
      overflow: hidden;
      box-shadow: var(--card-shadow);
      transition: all 0.3s;
      text-decoration: none;
      color: inherit;
      display: block;
    }
    
    .featured-card:hover {
      transform: translateY(-4px);
      box-shadow: var(--card-shadow-hover);
    }
    
    .featured-image {
      width: 100%;
      height: 220px;
      object-fit: cover;
      background: var(--border-color);
    }
    
    .featured-content {
      padding: 20px;
    }
    
    .featured-meta {
      display: flex;
      gap: 12px;
      margin-bottom: 12px;
      align-items: center;
    }
    
    .featured-category {
      padding: 4px 12px;
      border-radius: 12px;
      font-size: 0.75em;
      font-weight: 600;
      color: white;
    }
    
    .featured-source {
      font-size: 0.85em;
      color: var(--text-muted);
      font-weight: 500;
    }
    
    .featured-title {
      font-size: 1.3em;
      font-weight: 700;
      line-height: 1.3;
      margin-bottom: 8px;
      color: var(--text-primary);
    }
    
    .featured-description {
      font-size: 0.95em;
      color: var(--text-secondary);
      line-height: 1.5;
    }
    
    .list-section {
      margin-top: 48px;
    }
    
    .article-list {
      display: flex;
      flex-direction: column;
      gap: 20px;
    }
    
    .article-item {
      display: flex;
      gap: 20px;
      background: var(--bg-secondary);
      border-radius: 12px;
      padding: 16px;
      box-shadow: var(--card-shadow);
      transition: all 0.2s;
      text-decoration: none;
      color: inherit;
    }
    
    .article-item:hover {
      transform: translateX(4px);
      box-shadow: var(--card-shadow-hover);
    }
    
    .article-thumbnail {
      width: 180px;
      min-width: 180px;
      height: 120px;
      border-radius: 12px;
      object-fit: cover;
      background: var(--border-color);
    }
    
    .article-details {
      flex: 1;
      display: flex;
      flex-direction: column;
      justify-content: center;
    }
    
    .article-meta {
      display: flex;
      gap: 12px;
      margin-bottom: 8px;
      align-items: center;
    }
    
    .article-category {
      padding: 3px 10px;
      border-radius: 10px;
      font-size: 0.7em;
      font-weight: 600;
      color: white;
    }
    
    .article-source {
      font-size: 0.8em;
      color: var(--text-muted);
      font-weight: 500;
    }
    
    .article-date {
      font-size: 0.8em;
      color: var(--text-muted);
    }
    
    .article-title {
      font-size: 1.15em;
      font-weight: 600;
      line-height: 1.4;
      margin-bottom: 6px;
      color: var(--text-primary);
    }
    
    .article-description {
      font-size: 0.9em;
      color: var(--text-secondary);
      line-height: 1.5;
    }
    
    .pagination {
      display: flex;
      justify-content: center;
      gap: 12px;
      margin-top: 48px;
    }
    
    .pagination a, .pagination span {
      padding: 10px 20px;
      border-radius: 24px;
      background: var(--bg-secondary);
      border: 1px solid var(--border-color);
      text-decoration: none;
      color: var(--text-primary);
      font-weight: 500;
    }
    
    .pagination a:hover {
      background: var(--accent-color);
      color: white;
      border-color: var(--accent-color);
    }
    
    .alert {
      background: #d1f4e0;
      color: #0d7d3a;
      padding: 16px 24px;
      border-radius: 12px;
      margin-bottom: 24px;
      font-weight: 500;
    }
    
    [data-theme="dark"] .alert {
      background: #1e3a28;
      color: #68d391;
    }
    
    .empty-state {
      text-align: center;
      padding: 80px 24px;
      background: var(--bg-secondary);
      border-radius: 16px;
    }
    
    .empty-state h2 {
      font-size: 1.8em;
      margin-bottom: 12px;
      color: var(--text-primary);
    }
    
    .empty-state p {
      color: var(--text-secondary);
      font-size: 1.1em;
    }
    
    @media (max-width: 768px) {
      .featured-grid {
        grid-template-columns: 1fr;
      }
      
      .article-item {
        flex-direction: column;
      }
      
      .article-thumbnail {
        width: 100%;
        height: 200px;
      }
      
      .search-box input {
        min-width: 150px;
      }
    }
  </style>
  <script>
    function toggleTheme() {
      const html = document.documentElement;
      const currentTheme = html.getAttribute('data-theme');
      const newTheme = currentTheme === 'dark' ? 'light' : 'dark';
      
      html.setAttribute('data-theme', newTheme);
      localStorage.setItem('theme', newTheme);
      updateThemeIcon(newTheme);
    }
    
    function updateThemeIcon(theme) {
      const sunIcon = document.getElementById('sun-icon');
      const moonIcon = document.getElementById('moon-icon');
      
      if (theme === 'dark') {
        sunIcon.style.display = 'block';
        moonIcon.style.display = 'none';
      } else {
        sunIcon.style.display = 'none';
        moonIcon.style.display = 'block';
      }
    }
    
    document.addEventListener('DOMContentLoaded', function() {
      const savedTheme = localStorage.getItem('theme') || 'light';
      // Set theme immediately on html element before page renders
      document.documentElement.setAttribute('data-theme', savedTheme);
      updateThemeIcon(savedTheme);
    });
    
    // Set theme before page loads to prevent flash
    (function() {
      const savedTheme = localStorage.getItem('theme') || 'light';
      document.documentElement.setAttribute('data-theme', savedTheme);
    })();
  </script>
</head>
<body>
  <header class="header">
    <div class="header-content">
      <a href="/" class="logo">News-ish</a>
      <div class="header-actions">
        <form action="/refresh" method="post" style="display: inline;">
          <button type="submit" class="btn btn-secondary">Refresh</button>
        </form>
        <button class="theme-toggle" onclick="toggleTheme()" aria-label="Toggle theme">
          <svg id="sun-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" style="display: none;">
            <path d="M12 18a6 6 0 1 1 0-12 6 6 0 0 1 0 12zm0-2a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM11 1h2v3h-2V1zm0 19h2v3h-2v-3zM3.515 4.929l1.414-1.414L7.05 5.636 5.636 7.05 3.515 4.93zM16.95 18.364l1.414-1.414 2.121 2.121-1.414 1.414-2.121-2.121zm2.121-14.85l1.414 1.415-2.121 2.121-1.414-1.414 2.121-2.121zM5.636 16.95l1.414 1.414-2.121 2.121-1.414-1.414 2.121-2.121zM23 11v2h-3v-2h3zM4 11v2H1v-2h3z"/>
          </svg>
          <svg id="moon-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" style="display: block;">
            <path d="M10 7a7 7 0 0 0 12 4.9v.1c0 5.523-4.477 10-10 10S2 17.523 2 12 6.477 2 12 2h.1A6.979 6.979 0 0 0 10 7zm-6 5a8 8 0 0 0 15.062 3.762A9 9 0 0 1 8.238 4.938 7.999 7.999 0 0 0 4 12z"/>
          </svg>
        </button>
        <form action="/search" method="get" class="search-box">
          <input type="text" name="q" placeholder="Search news..." value="<%= params[:q] %>">
          <button type="submit" class="btn btn-primary">Search</button>
        </form>
      </div>
    </div>
  </header>
  
  <div class="container">
    <%= yield %>
  </div>
</body>
</html>

@@index
<% if params[:refreshed] %>
  <div class="alert">
    ✓ Feeds refreshed! <%= params[:new] %> new articles added.
  </div>
<% end %>

    <div class="filters">
      <select class="filter-select" onchange="window.location.href = this.value === '' ? '/' : '/?source=' + encodeURIComponent(this.value) + '<%= "&category=#{CGI.escape(@category)}" if @category && !@category.empty? %>'">
        <option value="">All Sources</option>
        <% @sources.each do |source| %>
          <option value="<%= source['source'] %>" <%= 'selected' if @source == source['source'] %>>
            <%= source['source'] %>
          </option>
        <% end %>
      </select>
    </div>

    <div class="category-pills">
      <a href="/<%= "?source=#{CGI.escape(@source)}" if @source && !@source.empty? %>" class="category-pill <%= 'active' unless @category %>" style="background: #6b7280;">All</a>
      <% @categories.each do |cat| %>
        <a href="/?category=<%= CGI.escape(cat['category']) %><%= "&source=#{CGI.escape(@source)}" if @source && !@source.empty? %>" 
           class="category-pill <%= 'active' if @category == cat['category'] %>"
           style="background: <%= category_color(cat['category']) %>;">
          <%= cat['category'] %>
        </a>
      <% end %>
    </div>

<% featured_articles = @articles.take(6) %>
<% remaining_articles = @articles.drop(6) %>

<% if featured_articles.any? %>
  <div class="section-header">
    <h2 class="section-title">Latest News</h2>
  </div>

  <div class="featured-grid">
    <% featured_articles.each do |article| %>
      <a href="<%= article['link'] %>" target="_blank" class="featured-card">
        <% if article['local_image'] %>
          <img src="<%= article['local_image'] %>" alt="" class="featured-image">
        <% end %>
        <div class="featured-content">
          <div class="featured-meta">
            <% if article['category'] %>
              <span class="featured-category" style="background: <%= category_color(article['category']) %>;">
                <%= article['category'] %>
              </span>
            <% end %>
            <span class="featured-source"><%= article['source'] %></span>
          </div>
          <h3 class="featured-title"><%= article['title'] %></h3>
          <p class="featured-description"><%= truncate_text(article['description'], 120) %></p>
        </div>
      </a>
    <% end %>
  </div>
<% end %>

<% if remaining_articles.any? %>
  <div class="list-section">
    <div class="section-header">
      <h2 class="section-title">More Stories</h2>
    </div>
    
    <div class="article-list">
      <% remaining_articles.each do |article| %>
        <a href="<%= article['link'] %>" target="_blank" class="article-item">
          <% if article['local_image'] %>
            <img src="<%= article['local_image'] %>" alt="" class="article-thumbnail">
          <% end %>
          <div class="article-details">
            <div class="article-meta">
              <% if article['category'] %>
                <span class="article-category" style="background: <%= category_color(article['category']) %>;">
                  <%= article['category'] %>
                </span>
              <% end %>
              <span class="article-source"><%= article['source'] %></span>
              <span class="article-date">
                <%= article['pub_date'] ? Date.parse(article['pub_date']).strftime('%b %d') : '' rescue '' %>
              </span>
            </div>
            <h3 class="article-title"><%= article['title'] %></h3>
            <p class="article-description"><%= truncate_text(article['description'], 100) %></p>
          </div>
        </a>
      <% end %>
    </div>
  </div>
<% end %>

<% if @articles.empty? %>
  <div class="empty-state">
    <h2>No articles found</h2>
    <p>Try refreshing or selecting a different category</p>
  </div>
<% end %>

<div class="pagination">
  <% if @page > 1 %>
    <a href="/?page=<%= @page - 1 %><%= "&source=#{CGI.escape(@source)}" if @source && !@source.empty? %><%= "&category=#{CGI.escape(@category)}" if @category && !@category.empty? %>">← Previous</a>
  <% end %>
  <span>Page <%= @page %></span>
  <% if @articles.length == @per_page %>
    <a href="/?page=<%= @page + 1 %><%= "&source=#{CGI.escape(@source)}" if @source && !@source.empty? %><%= "&category=#{CGI.escape(@category)}" if @category && !@category.empty? %>">Next →</a>
  <% end %>
</div>

@@search
<div class="section-header">
  <h2 class="section-title">
    <% if @query %>
      Search: "<%= @query %>"
    <% else %>
      Search Results
    <% end %>
  </h2>
</div>

<% if @articles.any? %>
  <div class="article-list">
    <% @articles.each do |article| %>
      <a href="<%= article['link'] %>" target="_blank" class="article-item">
        <% if article['local_image'] %>
          <img src="<%= article['local_image'] %>" alt="" class="article-thumbnail">
        <% end %>
        <div class="article-details">
          <div class="article-meta">
            <% if article['category'] %>
              <span class="article-category" style="background: <%= category_color(article['category']) %>;">
                <%= article['category'] %>
              </span>
            <% end %>
            <span class="article-source"><%= article['source'] %></span>
            <span class="article-date">
              <%= article['pub_date'] ? Date.parse(article['pub_date']).strftime('%b %d') : '' rescue '' %>
            </span>
          </div>
          <h3 class="article-title"><%= article['title'] %></h3>
          <p class="article-description"><%= truncate_text(article['description'], 100) %></p>
        </div>
      </a>
    <% end %>
  </div>
<% else %>
  <div class="empty-state">
    <h2>No results found</h2>
    <p>Try a different search term</p>
  </div>
<% end %>

@@stats
<div class="section-header">
  <h2 class="section-title">Statistics</h2>
</div>

<div class="featured-grid">
  <div class="featured-card" style="text-align: center; padding: 40px;">
    <div style="font-size: 3em; font-weight: 700; color: var(--accent-color);"><%= @stats[:total] %></div>
    <div style="color: var(--text-secondary); margin-top: 8px; font-size: 1.1em;">Total Articles</div>
  </div>
  
  <% @stats[:by_category].take(3).each do |cat| %>
    <div class="featured-card" style="text-align: center; padding: 40px;">
      <div style="font-size: 3em; font-weight: 700; color: <%= category_color(cat['category']) %>;"><%= cat['count'] %></div>
      <div style="color: var(--text-secondary); margin-top: 8px; font-size: 1.1em;"><%= cat['category'] %></div>
    </div>
  <% end %>
</div>

<div style="margin-top: 48px;">
  <h3 style="font-size: 1.5em; font-weight: 700; margin-bottom: 24px;">By Source</h3>
  <div class="article-list">
    <% @stats[:by_source].each do |source| %>
      <div class="article-item" style="cursor: default;">
        <div class="article-details">
          <div style="display: flex; justify-content: space-between; align-items: center;">
            <h3 class="article-title"><%= source['source'] %></h3>
            <div style="font-size: 1.5em; font-weight: 700; color: var(--accent-color);"><%= source['count'] %></div>
          </div>
        </div>
      </div>
    <% end %>
  </div>
</div>

<div style="margin-top: 40px; text-align: center;">
  <a href="/" class="btn btn-primary">← Back to News</a>
</div>
