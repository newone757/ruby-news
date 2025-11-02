#!/usr/bin/env ruby
require 'rss'
require 'open-uri'
require 'sqlite3'
require 'date'

class NewsAggregator
  def initialize(db_path = 'news.db')
    @db = SQLite3::Database.new(db_path)
    @db.results_as_hash = true
    setup_database
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
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      );
    SQL
  end

  def fetch_feed(url, source_name)
    puts "📡 Fetching #{source_name}..."
    
    begin
      URI.open(url) do |rss|
        feed = RSS::Parser.parse(rss)
        articles_added = 0
        
        feed.items.each do |item|
          begin
            @db.execute(
              "INSERT INTO articles (title, link, description, pub_date, source) VALUES (?, ?, ?, ?, ?)",
              [item.title, item.link, item.description, item.pubDate.to_s, source_name]
            )
            articles_added += 1
          rescue SQLite3::ConstraintException
            # Article already exists, skip it
          end
        end
        
        puts "✅ Added #{articles_added} new articles from #{source_name}"
      end
    rescue => e
      puts "❌ Error fetching #{source_name}: #{e.message}"
    end
  end

  def fetch_all_feeds
    feeds = {
      'BBC News' => 'http://feeds.bbci.co.uk/news/rss.xml',
      'TechCrunch' => 'https://techcrunch.com/feed/',
      'Hacker News' => 'https://hnrss.org/frontpage',
      'The Verge' => 'https://www.theverge.com/rss/index.xml'
    }

    feeds.each { |name, url| fetch_feed(url, name) }
  end

  def display_articles(limit = 20)
    puts "\n" + "=" * 80
    puts "📰 LATEST NEWS ARTICLES".center(80)
    puts "=" * 80 + "\n"

    rows = @db.execute(
      "SELECT * FROM articles ORDER BY created_at DESC LIMIT ?", 
      [limit]
    )

    if rows.empty?
      puts "No articles found. Run with 'fetch' to download news."
      return
    end

    rows.each_with_index do |article, idx|
      puts "\n#{idx + 1}. #{article['title']}"
      puts "   Source: #{article['source']} | Date: #{article['pub_date']}"
      puts "   🔗 #{article['link']}"
      
      # Only show description if it exists and isn't just a URL
      desc = article['description']
      if desc && desc.length > 50 && !desc.start_with?('Article URL:')
        puts "   #{desc[0..150]}..."
      end
      
      puts "-" * 80
    end

    total_count = @db.execute("SELECT COUNT(*) as count FROM articles")[0]['count']
    puts "\n📊 Total articles in database: #{total_count}"
  end

  def search_articles(query)
    puts "\n🔍 Searching for: '#{query}'\n"
    puts "=" * 80

    rows = @db.execute(
      "SELECT * FROM articles WHERE title LIKE ? OR description LIKE ? ORDER BY created_at DESC",
      ["%#{query}%", "%#{query}%"]
    )

    if rows.empty?
      puts "No articles found matching '#{query}'"
      return
    end

    rows.each_with_index do |article, idx|
      puts "\n#{idx + 1}. #{article['title']}"
      puts "   Source: #{article['source']}"
      puts "   🔗 #{article['link']}"
      puts "-" * 80
    end
  end

  def stats
    puts "\n📊 DATABASE STATISTICS"
    puts "=" * 80
    
    total = @db.execute("SELECT COUNT(*) as count FROM articles")[0]['count']
    puts "Total articles: #{total}"
    
    by_source = @db.execute("SELECT source, COUNT(*) as count FROM articles GROUP BY source")
    puts "\nArticles by source:"
    by_source.each do |row|
      puts "  #{row['source']}: #{row['count']}"
    end
  end

  def close
    @db.close
  end
end

# Main program
def show_help
  puts <<-HELP
  
📰 RSS News Aggregator

Usage:
  ruby news_aggregator.rb [command] [options]

Commands:
  fetch              Fetch latest articles from RSS feeds
  show [limit]       Display articles (default: 20)
  search <query>     Search articles by keyword
  stats              Show database statistics
  help               Show this help message

Examples:
  ruby news_aggregator.rb fetch
  ruby news_aggregator.rb show 10
  ruby news_aggregator.rb search "ruby programming"

  HELP
end

if __FILE__ == $0
  command = ARGV[0] || 'show'
  
  aggregator = NewsAggregator.new

  case command
  when 'fetch'
    aggregator.fetch_all_feeds
    aggregator.display_articles(10)
  when 'show'
    limit = (ARGV[1] || 20).to_i
    aggregator.display_articles(limit)
  when 'search'
    query = ARGV[1..-1].join(' ')
    if query.empty?
      puts "Please provide a search query"
    else
      aggregator.search_articles(query)
    end
  when 'stats'
    aggregator.stats
  when 'help'
    show_help
  else
    puts "Unknown command: #{command}"
    show_help
  end

  aggregator.close
end