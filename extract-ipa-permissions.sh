#!/bin/bash

set -e

VERBOSE=0

# Parse arguments
while [[ "$1" != "" ]]; do
    case $1 in
        --verbose ) VERBOSE=1
                    ;;
        * )         IPA_PATH=$1
                    ;;
    esac
    shift
done

if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
    echo "Usage: $0 [--verbose] <path-to-ipa>" >&2
    echo "Error: IPA file not found: $IPA_PATH" >&2
    exit 1
fi

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] $@" >&2
    fi
}

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log "Extracting IPA: $IPA_PATH"
log "Using temporary directory: $TEMP_DIR"

# Extract and find Info.plist
log "Unzipping IPA file..."
unzip -q "$IPA_PATH" -d "$TEMP_DIR" 2>/dev/null

log "Searching for .app bundle..."
APP_DIR=$(find "$TEMP_DIR/Payload" -name "*.app" -type d | head -1)

if [ -z "$APP_DIR" ]; then
    echo "Error: No .app bundle found in IPA" >&2
    exit 1
fi

log "Found app bundle: $(basename "$APP_DIR")"

INFO_PLIST="$APP_DIR/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "Error: Info.plist not found in app bundle" >&2
    exit 1
fi

log "Found Info.plist at: $INFO_PLIST"

# Check plist format
if [ "$VERBOSE" -eq 1 ]; then
    PLIST_TYPE=$(file "$INFO_PLIST")
    log "Info.plist format: $PLIST_TYPE"
fi

# Convert plist to JSON directly using plutil
PLIST_JSON="$TEMP_DIR/plist.json"
log "Converting Info.plist to JSON..."
if ! plutil -convert json "$INFO_PLIST" -o "$PLIST_JSON" 2>/dev/null; then
    echo "Error: Could not convert Info.plist to JSON" >&2
    exit 1
fi

log "Successfully converted to JSON: $PLIST_JSON"

# Show plist keys if verbose
if [ "$VERBOSE" -eq 1 ]; then
    log "Available plist keys:"
    jq -r 'keys[]' "$PLIST_JSON" | while read key; do
        log "  - $key"
    done
fi

log "Extracting privacy permissions using jq..."

# Use jq to extract permissions safely and generate valid JSON
RESULT=$(jq -n \
  --arg platform "ios" \
  --arg source "ipa" \
  --arg ipa_path "$IPA_PATH" \
  --arg app_bundle "$(basename "$APP_DIR")" \
  --arg extracted_at "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
  --argjson plist "$(cat "$PLIST_JSON")" \
  '{
    platform: $platform,
    source: $source,
    ipaPath: $ipa_path,
    appBundle: $app_bundle,
    extractedAt: $extracted_at,
    permissions: (
      $plist | 
      to_entries | 
      map(select(
        .key | test("Usage|Permission|Privacy"; "i") or 
               test("^NS.*Usage") or 
               test("UsageDescription$") or
               test("^Privacy")
      )) |
      from_entries
    ),
    totalPermissions: (
      $plist | 
      to_entries | 
      map(select(
        .key | test("Usage|Permission|Privacy"; "i") or 
               test("^NS.*Usage") or 
               test("UsageDescription$") or
               test("^Privacy")
      )) |
      length
    )
  }' 2>/dev/null)

log "Generated permissions JSON successfully"

# Show extracted permissions if verbose
if [ "$VERBOSE" -eq 1 ]; then
    PERM_COUNT=$(echo "$RESULT" | jq '.totalPermissions')
    log "Found $PERM_COUNT iOS permissions:"
    echo "$RESULT" | jq -r '.permissions | to_entries[] | "  - " + .key + ": " + .value' >&2
fi

# Validate and output
if [ $? -eq 0 ] && echo "$RESULT" | jq empty 2>/dev/null; then
    echo "$RESULT"
else
    echo "Error: Failed to generate valid JSON from Info.plist" >&2
    exit 1
fi
