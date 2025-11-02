# 📰 Ruby/Sinatra Web News Setup Guide

This guide explains how to install dependencies, configure your environment, and run the **Ruby/Sinatra web-news** application.

---

## 📑 Table of Contents
1. [Install Ruby](#1-install-ruby)
2. [Install Dependencies](#2-install-dependencies)
   - [Option A: Direct Gem Installation](#option-a-direct-gem-installation)
   - [Option B: Using Bundler (Recommended)](#option-b-using-bundler-recommended)
3. [Prepare the Environment](#3-prepare-the-environment)
   - [Unsplash API Setup](#unsplash-api-setup)
4. [Run the Application](#4-run-the-application)

---

## 1. Install Ruby

Most Arch-based systems include Ruby by default.  
If not, install it using your package manager:

**For Arch Linux:**
    
    sudo pacman -S ruby

**For Debian/Ubuntu:**
    
    sudo apt install ruby

---

## 2. Install Dependencies

### Option A: Direct Gem Installation

Install required gems manually:
    
    gem install sqlite3 rss sinatra erb

---

### Option B: Using Bundler (Recommended)

Bundler helps manage and isolate project dependencies cleanly.

#### Install Bundler
    
    gem install bundler

#### Create a `Gemfile`

In your project root directory:
    
    cat > Gemfile << 'EOF'
    source 'https://rubygems.org'

    gem 'rss'
    gem 'sqlite3'
    gem 'sinatra'
    gem 'erb'
    EOF

#### Install Dependencies
    
    bundle install

---

## 3. Prepare the Environment

Inside your project directory, create the following folders:
    
    mkdir -p public/images/articles

### Unsplash API Setup

1. Go to [Unsplash Developers](https://unsplash.com/developers)  
2. Create a free account and a new app  
3. Copy your **Access Key**  
4. Set it as an environment variable:
    
       export UNSPLASH_ACCESS_KEY='your_key_here'

---

## 4. Run the Application

Run directly using Ruby:
    
    ruby web-news.rb

Or, to run with Bundler:
    
    bundle exec ruby web-news.rb

---

✅ **Done!**  
Your Sinatra app should now be running locally. Open your browser and visit:
    
    http://localhost:4567

