"""
YouTube Transcript Extractor
Usage: python youtube_transcribe.py <youtube_url>
"""

import subprocess
import sys
import os
import json
import re

def get_video_info(url):
    """Get video title and check for available subtitles"""
    result = subprocess.run(
        ['yt-dlp', '--dump-json', '--skip-download', url],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"Error getting video info: {result.stderr}")
        return None
    return json.loads(result.stdout)

def check_captions(url):
    """Check what captions are available"""
    result = subprocess.run(
        ['yt-dlp', '--list-subs', url],
        capture_output=True, text=True
    )
    return result.stdout + result.stderr

def download_captions(url, output_dir="."):
    """Download captions/subtitles"""
    # Try to get English captions (auto or manual)
    result = subprocess.run(
        [
            'yt-dlp',
            '--write-auto-sub',
            '--write-sub',
            '--sub-lang', 'en',
            '--sub-format', 'vtt',
            '--skip-download',
            '--output', os.path.join(output_dir, '%(title)s.%(ext)s'),
            url
        ],
        capture_output=True, text=True
    )
    return result

def parse_vtt_to_text(vtt_content):
    """Convert VTT subtitle format to plain text"""
    lines = vtt_content.split('\n')
    text_lines = []
    seen = set()
    
    for line in lines:
        # Skip headers, timestamps, and empty lines
        if line.startswith('WEBVTT') or line.startswith('Kind:') or line.startswith('Language:'):
            continue
        if '-->' in line:  # Timestamp line
            continue
        if not line.strip():
            continue
        if line.strip().isdigit():  # Line numbers
            continue
            
        # Clean up the line
        clean_line = re.sub(r'<[^>]+>', '', line)  # Remove HTML tags
        clean_line = clean_line.strip()
        
        if clean_line and clean_line not in seen:
            seen.add(clean_line)
            text_lines.append(clean_line)
    
    return ' '.join(text_lines)

def main():
    if len(sys.argv) < 2:
        print("Usage: python youtube_transcribe.py <youtube_url>")
        sys.exit(1)
    
    url = sys.argv[1]
    print(f"\n{'='*60}")
    print(f"YouTube Transcript Extractor")
    print(f"{'='*60}")
    print(f"\nURL: {url}\n")
    
    # Get video info
    print("Fetching video info...")
    info = get_video_info(url)
    if info:
        print(f"Title: {info.get('title', 'Unknown')}")
        print(f"Duration: {info.get('duration', 0)} seconds ({info.get('duration', 0)//60} min {info.get('duration', 0)%60} sec)")
        print(f"Channel: {info.get('channel', 'Unknown')}")
    
    # Check available captions
    print(f"\n{'='*60}")
    print("Checking for captions...")
    print(f"{'='*60}")
    caption_info = check_captions(url)
    
    has_auto = 'en (auto-generated)' in caption_info.lower() or 'en-orig' in caption_info.lower()
    has_manual = bool(re.search(r'\ben\b(?!.*auto)', caption_info, re.IGNORECASE))
    
    if 'has no' in caption_info.lower() and 'subtitles' in caption_info.lower():
        print("\n❌ NO CAPTIONS AVAILABLE")
        print("This video has no captions. Would need Whisper API to transcribe.")
        return
    
    if has_manual:
        print("\n✅ MANUAL CAPTIONS AVAILABLE (high quality)")
    elif has_auto:
        print("\n✅ AUTO-GENERATED CAPTIONS AVAILABLE")
    else:
        print("\n⚠️  Caption status unclear. Attempting download...")
    
    # Download captions
    print(f"\n{'='*60}")
    print("Downloading transcript...")
    print(f"{'='*60}")
    
    result = download_captions(url)
    
    # Find the downloaded VTT file
    vtt_files = [f for f in os.listdir('.') if f.endswith('.vtt')]
    
    if vtt_files:
        vtt_file = vtt_files[0]
        print(f"\n✅ Downloaded: {vtt_file}")
        
        # Read and parse the VTT file
        with open(vtt_file, 'r', encoding='utf-8') as f:
            vtt_content = f.read()
        
        transcript = parse_vtt_to_text(vtt_content)
        
        # Save as plain text
        txt_file = vtt_file.replace('.en.vtt', '.txt').replace('.vtt', '.txt')
        with open(txt_file, 'w', encoding='utf-8') as f:
            f.write(transcript)
        
        print(f"✅ Saved plain text: {txt_file}")
        
        print(f"\n{'='*60}")
        print("TRANSCRIPT PREVIEW (first 1000 chars)")
        print(f"{'='*60}")
        print(transcript[:1000])
        if len(transcript) > 1000:
            print(f"\n... [{len(transcript) - 1000} more characters]")
        
        print(f"\n{'='*60}")
        print(f"Total transcript length: {len(transcript)} characters")
        print(f"Approximate word count: {len(transcript.split())}")
        print(f"{'='*60}")
        
    else:
        print("\n❌ Could not download captions")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")

if __name__ == '__main__':
    main()
