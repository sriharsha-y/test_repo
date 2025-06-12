#!/bin/bash

set -e

VERBOSE=0
ARTIFACTS=()
DOWNLOADED_FILES=()

# Function for logging
log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] $@" >&2
    fi
}

# Function to clean up downloaded files
cleanup() {
    if [ ${#DOWNLOADED_FILES[@]} -gt 0 ]; then
        log "Cleaning up downloaded files..."
        for file in "${DOWNLOADED_FILES[@]}"; do
            if [ -f "$file" ]; then
                rm -f "$file"
                log "Removed: $file"
            fi
        done
    fi
}

trap cleanup EXIT

# Function to check if URL is from GoCD
is_gocd_url() {
    local url="$1"
    if [[ "$url" =~ /go/files/ ]] || \
       [[ "$url" =~ /go/artifacts/ ]] || \
       [[ "$url" =~ /api/files/ ]] || \
       [[ "$url" =~ gocd ]] || \
       [[ "$url" =~ :8153 ]] || \
       [[ "$url" =~ :8154 ]]; then
        return 0
    fi
    return 1
}

# Function to build SSL options for curl
get_ssl_options() {
    local url="$1"
    local ssl_options=""
    
    if [ "$CURL_INSECURE" = "1" ] || [ "$GOCD_INSECURE" = "1" ]; then
        ssl_options="--insecure"
        log "Using --insecure flag (SSL verification disabled)"
    elif [ -n "$CURL_CA_BUNDLE" ]; then
        ssl_options="--cacert \"$CURL_CA_BUNDLE\""
        log "Using custom CA bundle: $CURL_CA_BUNDLE"
    elif [ -n "$GOCD_CA_BUNDLE" ]; then
        ssl_options="--cacert \"$GOCD_CA_BUNDLE\""
        log "Using GoCD CA bundle: $GOCD_CA_BUNDLE"
    elif is_gocd_url "$url"; then
        ssl_options="--insecure"
        log "GoCD URL detected, using --insecure"
    fi
    
    echo "$ssl_options"
}

# Function to download file with progress and GoCD authentication
download_file() {
    local url="$1"
    local temp_dir="$2"
    
    # Extract filename from URL or generate one
    local filename=$(basename "$url" | sed 's/[?&].*//')
    
    if [[ ! "$filename" =~ \.(ipa|apk|aab)$ ]]; then
        if [[ "$url" =~ \.ipa ]]; then
            filename="downloaded_app.ipa"
        elif [[ "$url" =~ \.aab ]]; then
            filename="downloaded_app.aab"
        elif [[ "$url" =~ \.apk ]]; then
            filename="downloaded_app.apk"
        else
            filename="downloaded_app.bin"
        fi
    fi
    
    local output_file="$temp_dir/$filename"
    
    # Progress messages go to stderr (won't be captured)
    echo "📥 Downloading: $(basename "$url")" >&2
    log "URL: $url"
    log "Output: $output_file"
    
    # Build curl command with SSL options
    local ssl_opts=$(get_ssl_options "$url")
    local auth_info=""
    local ssl_info=""
    
    if [[ "$ssl_opts" =~ --insecure ]]; then
        ssl_info=" (SSL bypass)"
    elif [[ "$ssl_opts" =~ --cacert ]]; then
        ssl_info=" (custom CA)"
    fi
    
    # Check authentication for GoCD URLs
    if is_gocd_url "$url"; then
        log "Detected GoCD URL, checking for authentication..."
        
        if [ -n "$GOCD_USERNAME" ] && [ -n "$GOCD_PASSWORD" ]; then
            log "Using GoCD authentication"
            auth_info=" (auth)"
        elif [ -n "$GOCD_TOKEN" ]; then
            log "Using GoCD token authentication"
            auth_info=" (token)"
        else
            echo "⚠️  No GoCD authentication provided" >&2
        fi
    fi
    
    echo "   Downloading$auth_info$ssl_info..." >&2
    
    # Execute curl command - progress bar will show on stderr
    local download_success=false
    if is_gocd_url "$url"; then
        if [ -n "$GOCD_USERNAME" ] && [ -n "$GOCD_PASSWORD" ]; then
            if curl -L $ssl_opts --progress-bar -u "$GOCD_USERNAME:$GOCD_PASSWORD" -o "$output_file" "$url"; then
                download_success=true
            fi
        elif [ -n "$GOCD_TOKEN" ]; then
            if curl -L $ssl_opts --progress-bar -H "Authorization: Bearer $GOCD_TOKEN" -o "$output_file" "$url"; then
                download_success=true
            fi
        else
            if curl -L $ssl_opts --progress-bar -o "$output_file" "$url"; then
                download_success=true
            fi
        fi
    else
        if curl -L $ssl_opts --progress-bar -o "$output_file" "$url"; then
            download_success=true
        fi
    fi
    
    if [ "$download_success" = false ]; then
        echo "❌ Failed to download: $url" >&2
        return 1
    fi
    
    # Verify the download
    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        echo "❌ Download failed or file is empty" >&2
        return 1
    fi
    
    # Check if we downloaded an HTML error page
    if file "$output_file" | grep -q "HTML"; then
        log "Downloaded file appears to be HTML, checking content..."
        if grep -qi "authentication\|login\|unauthorized\|forbidden" "$output_file" 2>/dev/null; then
            echo "❌ Authentication failed - downloaded error page" >&2
            rm -f "$output_file"
            return 1
        fi
    fi
    
    # Verify and rename file if needed
    local file_type=$(file "$output_file")
    log "Downloaded file type: $file_type"
    
    # DEBUG: Show file type for troubleshooting
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] File type detected: $file_type" >&2
        echo "[DEBUG] File size: $(du -h "$output_file" | cut -f1)" >&2
        echo "[DEBUG] File extension check: $filename" >&2
    fi
    
    # Handle .bin files that need renaming
    if [[ "$filename" == "downloaded_app.bin" ]]; then
        if [[ "$file_type" =~ "Zip archive" ]] && [[ "$url" =~ \.ipa ]]; then
            mv "$output_file" "${output_file%.bin}.ipa"
            output_file="${output_file%.bin}.ipa"
            filename="$(basename "$output_file")"
            log "Renamed to: $filename"
        elif [[ "$file_type" =~ "Zip archive" ]] && [[ "$url" =~ \.aab ]]; then
            mv "$output_file" "${output_file%.bin}.aab"
            output_file="${output_file%.bin}.aab"
            filename="$(basename "$output_file")"
            log "Renamed to: $filename"
        elif [[ "$file_type" =~ "Android application package" ]]; then
            mv "$output_file" "${output_file%.bin}.apk"
            output_file="${output_file%.bin}.apk"
            filename="$(basename "$output_file")"
            log "Renamed to: $filename"
        fi
    fi
    
    # IMPROVED FILE TYPE VALIDATION - more comprehensive patterns
    local valid_file=false
    
    # Check by file extension first (most reliable)
    if [[ "$output_file" =~ \.(ipa|apk|aab)$ ]]; then
        valid_file=true
        log "File validated by extension: $(basename "$output_file")"
    # Check by file type output (fallback)
    elif [[ "$file_type" =~ (Zip archive|ZIP archive|Archive|iOS App Store Package|Android application package|Java archive|JAR) ]]; then
        valid_file=true
        log "File validated by type: $file_type"
    # Special case for APK files that might be detected differently
    elif [[ "$file_type" =~ (application.*android|android.*application|APK|apk) ]]; then
        valid_file=true
        log "File validated as Android package: $file_type"
    fi
    
    if [ "$valid_file" = true ]; then
        echo "✅ Downloaded: $(basename "$output_file") ($(du -h "$output_file" | cut -f1))" >&2
        DOWNLOADED_FILES+=("$output_file")
        # CRITICAL: Output file path to stdout for capture
        echo "$output_file"
        return 0
    else
        echo "❌ Invalid file type detected: $file_type" >&2
        echo "   Expected: iOS/Android app package" >&2
        echo "   File: $(basename "$output_file")" >&2
        
        # Don't delete - keep for debugging
        if [ "$VERBOSE" -eq 1 ]; then
            echo "[DEBUG] File kept for inspection: $output_file" >&2
            echo "[DEBUG] First 100 bytes:" >&2
            hexdump -C "$output_file" | head -5 >&2
        else
            rm -f "$output_file"
        fi
        return 1
    fi
}

# Function to validate local file
validate_local_file() {
    local file_path="$1"
    
    if [ ! -f "$file_path" ]; then
        echo "❌ File not found: $file_path" >&2
        return 1
    fi
    
    if [[ ! "$file_path" =~ \.(ipa|apk|aab)$ ]]; then
        echo "❌ Unsupported file type: $file_path" >&2
        return 1
    fi
    
    if [ ! -s "$file_path" ]; then
        echo "❌ File is empty: $file_path" >&2
        return 1
    fi
    
    log "Validated local file: $file_path ($(du -h "$file_path" | cut -f1))"
    # Output only the file path to stdout
    echo "$file_path"
    return 0
}

# Function to process URL or local file
process_artifact() {
    local input="$1"
    local temp_dir="$2"
    
    if [[ "$input" =~ ^https?:// ]]; then
        download_file "$input" "$temp_dir"
    else
        validate_local_file "$input"
    fi
}

# Parse arguments
while [[ "$1" != "" ]]; do
    case $1 in
        --verbose ) 
            VERBOSE=1
            ;;
        --insecure )
            export CURL_INSECURE=1
            ;;
        --help | -h )
            echo "Usage: $0 [options] <artifact1> [artifact2] ..."
            echo ""
            echo "Options:"
            echo "  --verbose     Enable verbose logging"
            echo "  --insecure    Disable SSL certificate verification"
            echo "  --help        Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  GOCD_USERNAME     GoCD username"
            echo "  GOCD_PASSWORD     GoCD password"
            echo "  GOCD_INSECURE     Set to 1 to disable SSL verification for GoCD"
            echo ""
            echo "Examples:"
            echo "  $0 ./app.ipa ./app.aab"
            echo "  $0 https://gocd.company.com/go/artifacts/app.ipa"
            echo "  $0 --insecure https://internal-gocd/artifacts/app.ipa"
            exit 0
            ;;
        * )         
            ARTIFACTS+=("$1")
            ;;
    esac
    shift
done

if [ ${#ARTIFACTS[@]} -eq 0 ]; then
    echo "❌ No artifacts provided!"
    echo "Usage: $0 [options] <artifact1> [artifact2] ..."
    echo "Use --help for more information"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_FILE="$SCRIPT_DIR/baseline-permissions.json"

echo "=== Baseline Update Helper ==="
log "Artifacts to process: ${#ARTIFACTS[@]}"

# Check configuration
if [ "$CURL_INSECURE" = "1" ] || [ "$GOCD_INSECURE" = "1" ]; then
    echo "⚠️  SSL verification disabled"
fi

# Create temporary directory for downloads
TEMP_DIR=$(mktemp -d)
log "Temporary directory: $TEMP_DIR"

# Process each artifact
PROCESSED_FILES=()
echo ""
echo "📦 Processing artifacts..."

for artifact in "${ARTIFACTS[@]}"; do
    log "Processing artifact: $artifact"
    
    # FIXED: Don't redirect stderr - let progress messages show, only capture file path
    processed_file=$(process_artifact "$artifact" "$TEMP_DIR")
    if [ $? -eq 0 ] && [ -n "$processed_file" ] && [ -f "$processed_file" ]; then
        PROCESSED_FILES+=("$processed_file")
        echo "✅ Ready: $(basename "$processed_file")"
    else
        echo "❌ Failed to process: $artifact"
        exit 1
    fi
done

echo ""
echo "📋 Artifacts ready:"
for file in "${PROCESSED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "  - $(basename "$file") ($(du -h "$file" | cut -f1))"
    fi
done

if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
    echo "❌ No valid artifacts to process!"
    exit 1
fi

echo ""
echo "🔍 Extracting permissions..."

# Extract current permissions
CURRENT_PERMISSIONS="{\"ios\":{},\"android\":[]}"

for artifact in "${PROCESSED_FILES[@]}"; do
    if [[ "$artifact" == *.ipa ]]; then
        echo "📱 Processing iOS: $(basename "$artifact")"
        log "Processing iOS artifact: $artifact"
        
        if [ "$VERBOSE" -eq 1 ]; then
            IOS_PERMS=$("$SCRIPT_DIR/extract-ipa-permissions.sh" --verbose "$artifact")
        else
            IOS_PERMS=$("$SCRIPT_DIR/extract-ipa-permissions.sh" "$artifact")
        fi
        
        if [ $? -eq 0 ]; then
            CURRENT_PERMISSIONS=$(echo "$CURRENT_PERMISSIONS" | jq ".ios = ($IOS_PERMS | .permissions)")
            IOS_COUNT=$(echo "$IOS_PERMS" | jq '.totalPermissions')
            echo "   Found $IOS_COUNT iOS permissions"
        else
            echo "❌ Failed to extract iOS permissions"
            exit 1
        fi
        
    elif [[ "$artifact" == *.apk ]] || [[ "$artifact" == *.aab ]]; then
        echo "🤖 Processing Android: $(basename "$artifact")"
        log "Processing Android artifact: $artifact"
        
        if [ "$VERBOSE" -eq 1 ]; then
            ANDROID_PERMS=$("$SCRIPT_DIR/extract-android-permissions.sh" --verbose "$artifact")
        else
            ANDROID_PERMS=$("$SCRIPT_DIR/extract-android-permissions.sh" "$artifact")
        fi
        
        if [ $? -eq 0 ]; then
            CURRENT_PERMISSIONS=$(echo "$CURRENT_PERMISSIONS" | jq ".android = ($ANDROID_PERMS | .permissions)")
            ANDROID_COUNT=$(echo "$ANDROID_PERMS" | jq '.totalPermissions')
            echo "   Found $ANDROID_COUNT Android permissions"
        else
            echo "❌ Failed to extract Android permissions"
            exit 1
        fi
    fi
done

echo ""
echo "💾 Updating baseline..."

# Create new baseline
NEW_BASELINE=$(jq -n \
    --argjson current "$CURRENT_PERMISSIONS" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
    '{
        ios: $current.ios,
        android: $current.android,
        lastUpdated: $timestamp
    }')

echo "$NEW_BASELINE" > "$BASELINE_FILE"

echo "✅ Updated baseline:"
echo "   📱 iOS: $(echo "$CURRENT_PERMISSIONS" | jq '.ios | length') permissions"
echo "   🤖 Android: $(echo "$CURRENT_PERMISSIONS" | jq '.android | length') permissions"

echo ""
echo "📋 Next steps:"
echo "   1. Review: git diff $BASELINE_FILE"
echo "   2. Commit and create PR with justification"

log "Baseline update completed successfully"
