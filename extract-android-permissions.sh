#!/bin/bash

set -e

VERBOSE=0
ANDROID_BUILD_TOOLS_VERSION="35.0.0"

# Parse arguments
while [[ "$1" != "" ]]; do
    case $1 in
        --verbose ) VERBOSE=1
                    ;;
        * )         ARTIFACT_PATH=$1
                    ;;
    esac
    shift
done

if [ -z "$ARTIFACT_PATH" ] || [ ! -f "$ARTIFACT_PATH" ]; then
    echo "Usage: $0 [--verbose] <path-to-apk-or-aab>" >&2
    echo "Error: Android artifact not found: $ARTIFACT_PATH" >&2
    exit 1
fi

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] $@" >&2
    fi
}

# Function to normalize permission names by removing package prefix
normalize_permission() {
    local permission="$1"
    local package_name="$2"
    
    # Clean inputs of any whitespace/newlines
    permission=$(echo "$permission" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    package_name=$(echo "$package_name" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Remove package name prefix if present
    if [ -n "$package_name" ] && [[ "$permission" == "$package_name."* ]]; then
        echo "${permission#$package_name.}"
    else
        echo "$permission"
    fi
}

ARTIFACT_TYPE=""
if [[ "$ARTIFACT_PATH" == *.apk ]]; then
    ARTIFACT_TYPE="apk"
elif [[ "$ARTIFACT_PATH" == *.aab ]]; then
    ARTIFACT_TYPE="aab"
else
    echo "Error: Unsupported file type. Expected .apk or .aab" >&2
    exit 1
fi

log "Extracting Android permissions from $ARTIFACT_TYPE: $ARTIFACT_PATH"
log "File size: $(du -h "$ARTIFACT_PATH" | cut -f1)"

# Function to extract from APK
extract_from_apk() {
    local apk_path="$1"
    
    log "Extracting permissions from APK: $apk_path"
    
    # Try aapt2 first, fallback to aapt
    local aapt_cmd=""
    if command -v aapt2 >/dev/null 2>&1; then
        aapt_cmd="aapt2"
        log "Using aapt2 for extraction"
    elif [ -e "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION" ]; then
        aapt_cmd="$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2"
        log "Using aapt2 for extraction"
    elif command -v aapt >/dev/null 2>&1; then
        aapt_cmd="aapt"
        log "Using aapt for extraction"
    else
        echo "Error: Neither aapt nor aapt2 found. Please install Android SDK build-tools." >&2
        exit 1
    fi
    
    log "Running: $aapt_cmd dump permissions"
    
    # Extract all permissions
    PERMISSIONS_OUTPUT=$($aapt_cmd dump permissions "$apk_path" 2>/dev/null || echo "")
    
    log "Permission dump completed, parsing output..."
    
    # Extract package information with anchored patterns
    BADGING_OUTPUT=$($aapt_cmd dump badging "$apk_path" 2>/dev/null || echo "")

    # Extract using anchored grep to get the exact fields
    PACKAGE_NAME=$(echo "$BADGING_OUTPUT" | grep "^package:" | sed 's/^package: //' | grep -o "name='[^']*'" | cut -d"'" -f2 | head -1)
    VERSION_CODE=$(echo "$BADGING_OUTPUT" | grep "^package:" | sed 's/^package: //' | grep -o "versionCode='[^']*'" | cut -d"'" -f2 | head -1)
    VERSION_NAME=$(echo "$BADGING_OUTPUT" | grep "^package:" | sed 's/^package: //' | grep -o "versionName='[^']*'" | cut -d"'" -f2 | head -1)

    # Clean and validate
    PACKAGE_NAME=$(echo "$PACKAGE_NAME" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [ -z "$PACKAGE_NAME" ] || [[ "$PACKAGE_NAME" =~ ^[0-9]+$ ]]; then
        echo "Error: Failed to extract valid package name. Got: '$PACKAGE_NAME'" >&2
        exit 1
    fi

    log "Package info - Name: '$PACKAGE_NAME', Version: $VERSION_NAME ($VERSION_CODE)"

    
    # Parse permissions
    PERMISSION_LINES=$(echo "$PERMISSIONS_OUTPUT" | grep "uses-permission:" || echo "")
    PERM_LINE_COUNT=$(echo "$PERMISSION_LINES" | grep -c "uses-permission:" || echo "0")
    
    log "Found $PERM_LINE_COUNT permission entries"
    
    # Build permissions JSON
    local permissions_json="["
    local first=true
    
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            PERM_NAME=$(echo "$line" | sed -n "s/.*name='\([^']*\)'.*/\1/p")
            MAX_SDK=$(echo "$line" | sed -n "s/.*maxSdkVersion='\([^']*\)'.*/\1/p")
            
            if [ -n "$PERM_NAME" ]; then
                # Normalize permission for dynamic permissions
                NORMALIZED_PERM=$(normalize_permission "$PERM_NAME" "$PACKAGE_NAME")
                
                # Use normalized name for baseline comparison for dynamic permissions
                if [[ "$PERM_NAME" == "$PACKAGE_NAME."* ]]; then
                    BASELINE_PERM_NAME="$NORMALIZED_PERM"
                    log "Dynamic permission: $PERM_NAME -> $NORMALIZED_PERM"
                else
                    BASELINE_PERM_NAME="$PERM_NAME"
                fi
                
                log "Found permission: $PERM_NAME $([ -n "$MAX_SDK" ] && echo "(maxSdk: $MAX_SDK)")"
                
                if [ "$first" = true ]; then
                    first=false
                else
                    permissions_json="$permissions_json,"
                fi
                
                # Build permission object using baseline name
                if [ -n "$MAX_SDK" ]; then
                    permissions_json="$permissions_json{\"name\":\"$BASELINE_PERM_NAME\",\"maxSdkVersion\":\"$MAX_SDK\"}"
                else
                    permissions_json="$permissions_json{\"name\":\"$BASELINE_PERM_NAME\"}"
                fi
            fi
        fi
    done <<< "$PERMISSION_LINES"
    
    permissions_json="$permissions_json]"
    
    log "Built permissions JSON array"
    
    # Create final JSON output
    local result_json=$(jq -n \
        --arg platform "android" \
        --arg source "$ARTIFACT_TYPE" \
        --arg artifact_path "$apk_path" \
        --arg package_name "$PACKAGE_NAME" \
        --arg version_code "$VERSION_CODE" \
        --arg version_name "$VERSION_NAME" \
        --argjson permissions "$permissions_json" \
        --arg extracted_at "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            platform: $platform,
            source: $source,
            artifactPath: $artifact_path,
            extractedAt: $extracted_at,
            packageInfo: {
                packageName: $package_name,
                versionCode: $version_code,
                versionName: $version_name
            },
            permissions: $permissions,
            totalPermissions: ($permissions | length)
        }')
    
    log "Generated final JSON result"
    
    echo "$result_json"
}

# Function to extract from AAB
extract_from_aab() {
    local aab_path="$1"
    
    log "Processing AAB file: $aab_path"
    
    if ! command -v bundletool >/dev/null 2>&1; then
        echo "Error: bundletool not found. Required for AAB processing." >&2
        exit 1
    fi
    
    log "Found bundletool, proceeding with AAB extraction"
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT
    
    log "Using temporary directory: $TEMP_DIR"
    log "Extracting base APK from AAB using bundletool..."
    
    bundletool build-apks --bundle="$aab_path" --output="$TEMP_DIR/temp.apks" --mode=universal >/dev/null 2>&1
    
    log "Generated universal APK, extracting..."
    
    unzip -q "$TEMP_DIR/temp.apks" -d "$TEMP_DIR"
    
    BASE_APK=$(find "$TEMP_DIR" -name "*.apk" | head -1)
    
    if [ -z "$BASE_APK" ] || [ ! -f "$BASE_APK" ]; then
        echo "Error: Could not extract APK from AAB" >&2
        exit 1
    fi
    
    log "Found extracted APK: $(basename "$BASE_APK")"
    
    local apk_permissions=$(extract_from_apk "$BASE_APK")
    
    echo "$apk_permissions" | jq '.source = "aab" | .artifactPath = "'"$aab_path"'"'
}

# Main execution
if [ "$ARTIFACT_TYPE" = "apk" ]; then
    extract_from_apk "$ARTIFACT_PATH"
else
    extract_from_aab "$ARTIFACT_PATH"
fi
