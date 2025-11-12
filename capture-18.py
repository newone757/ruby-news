import asyncio
from playwright.async_api import async_playwright, TimeoutError as PlaywrightTimeoutError
import os
import sys
import random
import csv
import subprocess
import re
import time

CONCURRENT_PAGES = int(os.getenv('CONCURRENT_PAGES', 10))
MAX_WAIT = int(os.getenv('MAX_WAIT', 30000))
DELAY_AFTER_REDIRECT = int(os.getenv('DELAY_AFTER_REDIRECT', 8000))
WAIT_FOR_CLOUDFLARE = int(os.getenv('WAIT_FOR_CLOUDFLARE', 10000))

USER_AGENTS = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15',
]

def get_dns_and_ip_info(url):
    """Step 1: DNS resolution and IP ownership"""
    info = {
        'url': url,
        'resolved_ip': None,
        'ip_owner': None,
        'dns_success': False
    }
    
    hostname = url.replace('https://', '').replace('http://', '').split('/')[0].split(':')[0]
    
    try:
        dig_result = subprocess.run(
            ['dig', '+short', hostname, 'A'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        lines = [line.strip() for line in dig_result.stdout.strip().split('\n') if line.strip() and not line.startswith(';')]
        
        # Create IP regex pattern
        ip_regex = r'^\d+\.\d+\.\d+\.\d+$'
        valid_ips = []
        for line in lines:
            if re.match(ip_regex, line):
                valid_ips.append(line)
        
        if valid_ips:
            info['resolved_ip'] = valid_ips[0]
            info['dns_success'] = True
            
            try:
                whois_result = subprocess.run(
                    ['whois', info['resolved_ip']],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                whois_output = whois_result.stdout
                
                org_match = re.search(r'(?:OrgName|org-name|owner|descr):\s*(.+)', whois_output, re.IGNORECASE)
                if org_match:
                    info['ip_owner'] = org_match.group(1).strip()
                else:
                    netname_match = re.search(r'NetName:\s*(.+)', whois_output, re.IGNORECASE)
                    if netname_match:
                        info['ip_owner'] = netname_match.group(1).strip()
            except (subprocess.TimeoutExpired, Exception) as e:
                print(f"  [WHOIS ERROR] {hostname}: {e}")
        else:
            print(f"  [DNS FAILED] {hostname} - No valid IP address found")
            
    except subprocess.TimeoutExpired:
        print(f"  [DNS TIMEOUT] {hostname}")
    except FileNotFoundError:
        print(f"  [DNS ERROR] {hostname}: dig command not found")
    except Exception as e:
        print(f"  [DNS ERROR] {hostname}: {e}")
    
    return info

def get_curl_info(url, ip_address):
    """Step 2: Get HTTP headers and SSL cert info via curl"""
    info = {
        'status_code': None,
        'headers': None,
        'cert_issuer': None,
        'cert_subject': None,
        'cert_valid_from': None,
        'cert_valid_to': None,
        'cert_serial_number': None,
        'cert_fingerprint': None,
        'cert_chain_length': 0,
        'cert_chain_issuers': None,
        'curl_success': False
    }
    
    try:
        result = subprocess.run(
            ['curl', '-vI', '--max-time', '10', '--connect-timeout', '5', url],
            capture_output=True,
            text=True,
            timeout=15
        )
        
        output = result.stderr + result.stdout
        
        status_match = re.search(r'HTTP/[\d.]+ (\d+)', output)
        if status_match:
            info['status_code'] = int(status_match.group(1))
            info['curl_success'] = True
        
        headers_lines = []
        in_headers = False
        for line in result.stdout.split('\n'):
            if line.startswith('HTTP/'):
                in_headers = True
                continue
            if in_headers and line.strip():
                if ':' in line:
                    headers_lines.append(line.strip())
            elif in_headers and not line.strip():
                break
        info['headers'] = '\n'.join(headers_lines) if headers_lines else None
        
        subject_match = re.search(r'subject:[\s]*(.*?)(?:\n|$)', output)
        if subject_match:
            subject = subject_match.group(1).strip()
            cn_match = re.search(r'CN\s*=\s*([^,;]+)', subject)
            if cn_match:
                info['cert_subject'] = cn_match.group(1).strip()
            else:
                info['cert_subject'] = subject
        
        issuer_match = re.search(r'issuer:[\s]*(.*?)(?:\n|$)', output)
        if issuer_match:
            issuer = issuer_match.group(1).strip()
            cn_match = re.search(r'CN\s*=\s*([^,;]+)', issuer)
            if cn_match:
                info['cert_issuer'] = cn_match.group(1).strip()
            else:
                o_match = re.search(r'O\s*=\s*([^,;]+)', issuer)
                if o_match:
                    info['cert_issuer'] = o_match.group(1).strip()
                else:
                    info['cert_issuer'] = issuer
        
        start_date_match = re.search(r'start date:\s*(.*?)(?:\n|$)', output)
        if start_date_match:
            info['cert_valid_from'] = start_date_match.group(1).strip()
        
        expire_date_match = re.search(r'expire date:\s*(.*?)(?:\n|$)', output)
        if expire_date_match:
            info['cert_valid_to'] = expire_date_match.group(1).strip()
        
        serial_match = re.search(r'serial:\s*([A-Fa-f0-9:]+)', output)
        if serial_match:
            info['cert_serial_number'] = serial_match.group(1).strip()
        
        cert_count = output.count('Server certificate:')
        cert_count += output.count('Certificate chain')
        if cert_count > 0:
            chain_entries = re.findall(r'^\s*\d+\s+s:', output, re.MULTILINE)
            info['cert_chain_length'] = len(chain_entries) if chain_entries else 1
            
            chain_issuers = []
            for match in re.finditer(r'^\s*\d+\s+s:.*?CN\s*=\s*([^,\n]+)', output, re.MULTILINE):
                chain_issuers.append(match.group(1).strip())
            if chain_issuers:
                info['cert_chain_issuers'] = ' | '.join(chain_issuers)
        
    except subprocess.TimeoutExpired:
        print(f"  [CURL TIMEOUT] {url}")
        info['status_code'] = 'TIMEOUT'
    except Exception as e:
        print(f"  [CURL ERROR] {url}: {e}")
        info['status_code'] = f'ERROR: {str(e)}'
    
    return info

async def wait_for_cloudflare(page):
    """Wait for Cloudflare challenge to complete"""
    try:
        cloudflare_selectors = [
            'text=Checking your browser',
            'text=Verify you are human',
            '#challenge-running',
            '.cf-browser-verification',
        ]
        
        for selector in cloudflare_selectors:
            try:
                element = await page.query_selector(selector)
                if element:
                    print(f"  [CLOUDFLARE] Detected challenge, waiting...")
                    await asyncio.sleep(WAIT_FOR_CLOUDFLARE / 1000)
                    return True
            except:
                pass
        return False
    except Exception as e:
        return False

async def capture_page(page, url, output_file, curl_info):
    """Capture page screenshot"""
    metadata = {
        'url': url,
        'success': False,
    }
    
    metadata.update(curl_info)
    
    try:
        response = await page.goto(url, timeout=MAX_WAIT, wait_until='networkidle')
        
        if response and not metadata['status_code']:
            metadata['status_code'] = response.status
        
        await wait_for_cloudflare(page)
        await asyncio.sleep(DELAY_AFTER_REDIRECT / 1000)
        
        title = await page.title()
        content = await page.content()
        
        if 'cloudflare' in title.lower() or 'just a moment' in title.lower():
            print(f"[BLOCKED] {url} - Still on Cloudflare challenge page")
            metadata['status_code'] = 'BLOCKED_CLOUDFLARE'
            return metadata
        
        if 'checking your browser' in content.lower():
            print(f"[BLOCKED] {url} - Cloudflare verification in progress")
            metadata['status_code'] = 'BLOCKED_CLOUDFLARE'
            return metadata
            
        await page.screenshot(path=output_file, full_page=False)
        print(f"[SUCCESS] {url} -> {output_file}")
        metadata['success'] = True
        
    except PlaywrightTimeoutError:
        print(f"[TIMEOUT] {url}")
        if not metadata['status_code']:
            metadata['status_code'] = 'TIMEOUT'
    except Exception as e:
        print(f"[ERROR] {url}: {e}")
        if not metadata['status_code']:
            metadata['status_code'] = f'ERROR: {str(e)}'
    
    return metadata

async def process_urls(urls, output_dir, width, height, csv_file):
    start_time = time.time()
    results = []
    
    print("=" * 60)
    print("STEP 1: DNS Resolution & IP Ownership Lookup")
    print("=" * 60)
    dns_start = time.time()
    
    async def run_dns(url):
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, get_dns_and_ip_info, url)
    
    dns_tasks = [run_dns(url) for url in urls]
    dns_results = await asyncio.gather(*dns_tasks)
    dns_elapsed = time.time() - dns_start
    
    dns_resolved_urls = []
    dns_failed_urls = []
    url_to_dns_info = {}
    
    for dns_info in dns_results:
        url = dns_info['url']
        url_to_dns_info[url] = dns_info
        
        if dns_info['dns_success']:
            dns_resolved_urls.append(url)
        else:
            dns_failed_urls.append(url)
            dns_info['status_code'] = 'DNS_FAILED'
            results.append(dns_info)
    
    print(f"\nDNS Resolution complete: {len(dns_resolved_urls)} resolved, {len(dns_failed_urls)} failed (in {dns_elapsed:.2f}s)")
    if dns_failed_urls:
        print(f"Skipping {len(dns_failed_urls)} URLs that failed DNS resolution")
    
    if not dns_resolved_urls:
        print("\nNo URLs resolved DNS - skipping curl and screenshots")
        curl_successful_urls = []
        curl_elapsed = 0
        screenshot_count = 0
        screenshot_elapsed = 0
    else:
        print(f"\n{'=' * 60}")
        print(f"STEP 2: Curl Headers & Certificate Info")
        print(f"{'=' * 60}")
        curl_start = time.time()
        
        async def run_curl(url):
            loop = asyncio.get_event_loop()
            ip = url_to_dns_info[url]['resolved_ip']
            return await loop.run_in_executor(None, get_curl_info, url, ip)
        
        curl_tasks = [run_curl(url) for url in dns_resolved_urls]
        curl_data = await asyncio.gather(*curl_tasks)
        curl_elapsed = time.time() - curl_start
        
        curl_successful_urls = []
        curl_failed_urls = []
        url_to_full_info = {}
        
        for url, curl_info in zip(dns_resolved_urls, curl_data):
            full_info = {**url_to_dns_info[url], **curl_info}
            url_to_full_info[url] = full_info
            
            status = curl_info.get('status_code')
            if isinstance(status, int) and 200 <= status < 600:
                curl_successful_urls.append(url)
            else:
                print(f"[SKIP] {url} - Curl failed: {status}")
                curl_failed_urls.append(url)
                results.append(full_info)
        
        print(f"\nCurl complete: {len(curl_successful_urls)} successful, {len(curl_failed_urls)} failed (in {curl_elapsed:.2f}s)")
        if curl_failed_urls:
            print(f"Skipping {len(curl_failed_urls)} URLs that failed curl")
        
        if not curl_successful_urls:
            print("\nNo URLs passed curl - skipping screenshots")
            screenshot_count = 0
            screenshot_elapsed = 0
        else:
            print(f"\n{'=' * 60}")
            print(f"STEP 3: Capturing Screenshots")
            print(f"{'=' * 60}")
            print(f"Processing {len(curl_successful_urls)} URLs...\n")
            
            screenshot_start = time.time()
            screenshot_count = 0
            
            async with async_playwright() as p:
                browser = await p.chromium.launch(
                    headless=True,
                    args=[
                        '--disable-blink-features=AutomationControlled',
                        '--disable-features=IsolateOrigins,site-per-process',
                        '--disable-site-isolation-trials',
                    ]
                )
                
                context = await browser.new_context(
                    viewport={"width": width, "height": height},
                    user_agent=random.choice(USER_AGENTS),
                    locale='en-US',
                    timezone_id='America/New_York',
                    permissions=['geolocation'],
                    geolocation={'latitude': 40.7128, 'longitude': -74.0060},
                    color_scheme='light',
                    extra_http_headers={
                        'Accept-Language': 'en-US,en;q=0.9',
                        'Accept-Encoding': 'gzip, deflate, br',
                        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                        'Sec-Fetch-Dest': 'document',
                        'Sec-Fetch-Mode': 'navigate',
                        'Sec-Fetch-Site': 'none',
                        'Upgrade-Insecure-Requests': '1',
                    }
                )
                
                await context.add_init_script("""
                    Object.defineProperty(navigator, 'webdriver', {
                        get: () => undefined
                    });
                    
                    window.chrome = {
                        runtime: {}
                    };
                    
                    const originalQuery = window.navigator.permissions.query;
                    window.navigator.permissions.query = (parameters) => (
                        parameters.name === 'notifications' ?
                            Promise.resolve({ state: Cypress.env('notification_permission') || 'denied' }) :
                            originalQuery(parameters)
                    );
                """)
                
                semaphore = asyncio.Semaphore(CONCURRENT_PAGES)
                
                async def worker(url):
                    nonlocal screenshot_count
                    async with semaphore:
                        filename = url.replace("https://", "").replace("http://", "").replace("/", "_") + ".png"
                        output_file = os.path.join(output_dir, filename)
                        
                        page = await context.new_page()
                        await asyncio.sleep(random.uniform(0.5, 2.0))
                        
                        metadata = await capture_page(page, url, output_file, url_to_full_info.get(url, {}))
                        if metadata.get('success'):
                            screenshot_count += 1
                        results.append(metadata)
                        
                        await page.close()
                
                tasks = [asyncio.create_task(worker(url)) for url in curl_successful_urls]
                await asyncio.gather(*tasks)
                
                await context.close()
                await browser.close()
            
            screenshot_elapsed = time.time() - screenshot_start
    
    total_elapsed = time.time() - start_time
    
    with open(csv_file, 'w', newline='', encoding='utf-8') as f:
        fieldnames = [
            'url', 'status_code', 'resolved_ip', 'ip_owner', 'headers',
            'cert_issuer', 'cert_subject', 'cert_valid_from', 'cert_valid_to',
            'cert_serial_number', 'cert_fingerprint', 'cert_chain_length', 'cert_chain_issuers'
        ]
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        
        for result in results:
            writer.writerow({
                'url': result.get('url', ''),
                'status_code': result.get('status_code', ''),
                'resolved_ip': result.get('resolved_ip', ''),
                'ip_owner': result.get('ip_owner', ''),
                'headers': result.get('headers', ''),
                'cert_issuer': result.get('cert_issuer', ''),
                'cert_subject': result.get('cert_subject', ''),
                'cert_valid_from': result.get('cert_valid_from', ''),
                'cert_valid_to': result.get('cert_valid_to', ''),
                'cert_serial_number': result.get('cert_serial_number', ''),
                'cert_fingerprint': result.get('cert_fingerprint', ''),
                'cert_chain_length': result.get('cert_chain_length', 0),
                'cert_chain_issuers': result.get('cert_chain_issuers', '')
            })
    
    print(f"\n{'='*60}")
    print(f"FINAL SUMMARY")
    print(f"{'='*60}")
    print(f"Total URLs processed: {len(urls)}")
    print(f"")
    print(f"Step 1 - DNS Resolution:")
    print(f"  ✓ Resolved: {len(dns_resolved_urls)}")
    print(f"  ✗ Failed: {len(dns_failed_urls)}")
    print(f"  Time: {dns_elapsed:.2f}s")
    if dns_resolved_urls:
        print(f"")
        print(f"Step 2 - Curl (Headers/Certs):")
        print(f"  ✓ Successful: {len(curl_successful_urls)}")
        print(f"  ✗ Failed: {len(curl_failed_urls) if 'curl_failed_urls' in locals() else 0}")
        print(f"  Time: {curl_elapsed:.2f}s")
        if curl_successful_urls:
            print(f"")
            print(f"Step 3 - Screenshots:")
            print(f"  ✓ Captured: {screenshot_count}")
            print(f"  Time: {screenshot_elapsed:.2f}s")
    print(f"")
    print(f"Total time: {total_elapsed:.2f}s ({total_elapsed/60:.2f} minutes)")
    print(f"Metadata saved to: {csv_file}")
    print(f"{'='*60}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python capture.py <urls.txt>")
        sys.exit(1)
    
    urls_file = sys.argv[1]
    output_dir = "./captures"
    csv_output = "./captures/metadata.csv"
    width = int(os.getenv('WIDTH', 1280))
    height = int(os.getenv('HEIGHT', 720))
    
    os.makedirs(output_dir, exist_ok=True)
    
    with open(urls_file) as f:
        urls = [line.strip() for line in f if line.strip()]
    
    print(f"Loaded {len(urls)} URLs...")
    print(f"Settings: {CONCURRENT_PAGES} concurrent pages, {width}x{height} viewport\n")
    
    asyncio.run(process_urls(urls, output_dir, width, height, csv_output))
