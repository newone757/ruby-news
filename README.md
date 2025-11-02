# Install Ruby
## Ruby should already be installed on most Arch systems, but if not:
sudo pacman -S ruby

## or for debain-based systems
sudo apt install ruby

# Install dependencies
## Install the required gem (SQLite3 for database)
gem install sqlite3 rss sinatra erb

### OR for a more professional approach, use bundler to keep project dependencies osolated

## Install bundler if you don't have it
gem install bundler

## Create a Gemfile in your project directory
cat > Gemfile << 'EOF'
source 'https://rubygems.org'

gem 'rss'
gem 'sqlite3'
gem 'sinatra'
gem 'erb'
EOF

## Install bundle gems
bundle install

# Stage environment
## Within the folder where the code will exist
mkdir -p public/images/articles

## get unsplash dev api key
### Visit: https://unsplash.com/developers
### Create an account (free)
### Create a new app
### Copy your Access Key

### Set it as an environment variable:
export UNSPLASH_ACCESS_KEY='your_key_here'


# Run it
ruby web-news.rb

## To Run with bundler
bundle exec ruby web-news.rb



