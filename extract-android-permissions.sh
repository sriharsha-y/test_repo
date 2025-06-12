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

# Function to normalize permission names with debugging
normalize_permission() {
    local permission="$1"
    local package_name="$2"
    
    log "NORMALIZE_DEBUG: permission='$permission'"
    log "NORMALIZE_DEBUG: package_name='$package_name'" 
    log "NORMALIZE_DEBUG: expected_prefix='$package_name.'"
    
    # Remove package name prefix if present
    if [[ "$permission" == "$package_name."* ]]; then
        local normalized="${permission#$package_name.}"
        log "NORMALIZE_DEBUG: Match found, normalized='$normalized'"
        echo "$normalized"
    else
        log "NORMALIZE_DEBUG: No match, returning original"
        echo "$permission"
    fi
}

# Function to check if permission is dynamic with debugging
is_dynamic_permission() {
    local permission="$1"
    local package_name="$2"
    
    log "DYNAMIC_DEBUG: permission='$permission'"
    log "DYNAMIC_DEBUG: package_name='$package_name'"
    log "DYNAMIC_DEBUG: expected_prefix='$package_name.'"
    
    if [[ -z "$package_name" ]]; then
        log "DYNAMIC_DEBUG: Package name is empty!"
        return 1
    fi
    
    if [[ "$permission" == "$package_name."* ]]; then
        log "DYNAMIC_DEBUG: Match found - IS DYNAMIC"
        return 0  # true
    else
        log "DYNAMIC_DEBUG: No match - NOT DYNAMIC"
        return 1  # false
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
    
    # [Keep the existing aapt tool detection logic...]
    local aapt_cmd=""
    if command -v aapt2 >/dev/null 2>&1; then
        aapt_cmd="aapt2"
        log "Using aapt2 for extraction"
    elif [ -e "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2" ]; then
        aapt_cmd="$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt2"
        log "Using aapt2 for extraction"
    elif command -v aapt >/dev/null 2>&1; then
        aapt_cmd="aapt"
        log "Using aapt for extraction"
    else
        echo "Error: Neither aapt nor aapt2 found. Please install Android SDK build-tools." >&2
        exit 1
    fi
    
    # Extract permissions and package info
    PERMISSIONS_OUTPUT=$($aapt_cmd dump permissions "$apk_path" 2>/dev/null || echo "")
    
    # Extract package information with proper cleanup
    BADGING_OUTPUT=$($aapt_cmd dump badging "$apk_path" 2>/dev/null || echo "")

    log "Raw badging output (first few lines):"
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$BADGING_OUTPUT" | head -3 >&2
    fi

    # Extract package line and clean it up
    PACKAGE_LINE=$(echo "$BADGING_OUTPUT" | grep "^package:" | head -1 | tr -d '\n\r')
    log "Package line (cleaned): '$PACKAGE_LINE'"

    if [ -n "$PACKAGE_LINE" ]; then
        # More precise extraction with word boundaries
        PACKAGE_NAME=$(echo "$PACKAGE_LINE" | sed -n "s/.*name='\([^']*\)'.*/\1/p" | tr -d '\n\r' | sed 's/[[:space:]]*$//')
        VERSION_CODE=$(echo "$PACKAGE_LINE" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p" | tr -d '\n\r' | sed 's/[[:space:]]*$//')
        VERSION_NAME=$(echo "$PACKAGE_LINE" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    else
        # Fallback with better cleanup
        PACKAGE_NAME=$(echo "$BADGING_OUTPUT" | grep -o "name='[^']*'" | head -1 | cut -d"'" -f2 | tr -d '\n\r' | sed 's/[[:space:]]*$//')
        VERSION_CODE=$(echo "$BADGING_OUTPUT" | grep -o "versionCode='[^']*'" | head -1 | cut -d"'" -f2 | tr -d '\n\r' | sed 's/[[:space:]]*$//')
        VERSION_NAME=$(echo "$BADGING_OUTPUT" | grep -o "versionName='[^']*'" | head -1 | cut -d"'" -f2 | tr -d '\n\r' | sed 's/[[:space:]]*$//')
    fi

    # Additional cleanup and validation
    PACKAGE_NAME=$(echo "$PACKAGE_NAME" | sed 's/[^a-zA-Z0-9._-].*$//' | sed 's/[[:space:]]*$//')
    VERSION_CODE=$(echo "$VERSION_CODE" | sed 's/[^0-9].*$//' | sed 's/[[:space:]]*$//')
    VERSION_NAME=$(echo "$VERSION_NAME" | sed 's/[[:space:]]*$//')

    log "After cleanup - Package: '$PACKAGE_NAME', Version: '$VERSION_NAME', Code: '$VERSION_CODE'"

    # Validate package name format
    if [ -z "$PACKAGE_NAME" ] || [[ ! "$PACKAGE_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]]; then
        log "ERROR: Invalid package name format: '$PACKAGE_NAME'"
        log "Raw badging output for debugging:"
        log "$BADGING_OUTPUT"
        echo "Error: Failed to extract valid package name from APK" >&2
        exit 1
    fi

    log "Package info - Name: '$PACKAGE_NAME', Version: $VERSION_NAME ($VERSION_CODE)"

    
    # Parse permissions
    PERMISSION_LINES=$(echo "$PERMISSIONS_OUTPUT" | grep "uses-permission:" || echo "")
    PERM_LINE_COUNT=$(echo "$PERMISSION_LINES" | grep -c "uses-permission:" || echo "0")
    
    log "Found $PERM_LINE_COUNT permission entries"
    
    # Create temporary file for permissions data
    TEMP_PERMS=$(mktemp)
    trap "rm -f $TEMP_PERMS" EXIT
    
    # Process permissions and write to temp file as JSON Lines
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            PERM_NAME=$(echo "$line" | sed -n "s/.*name='\([^']*\)'.*/\1/p")
            MAX_SDK=$(echo "$line" | sed -n "s/.*maxSdkVersion='\([^']*\)'.*/\1/p")
            
            if [ -n "$PERM_NAME" ]; then
                # Normalize permission name
                NORMALIZED_PERM=$(normalize_permission "$PERM_NAME" "$PACKAGE_NAME")
                IS_DYNAMIC=$(is_dynamic_permission "$PERM_NAME" "$PACKAGE_NAME" && echo "true" || echo "false")
                
                log "Found permission: $PERM_NAME $([ "$IS_DYNAMIC" = "true" ] && echo "(dynamic, normalized: $NORMALIZED_PERM)") $([ -n "$MAX_SDK" ] && echo "(maxSdk: $MAX_SDK)")"
                
                # Use jq to create each permission object safely
                if [ -n "$MAX_SDK" ]; then
                    jq -n \
                        --arg name "$PERM_NAME" \
                        --arg normalized "$NORMALIZED_PERM" \
                        --arg dynamic "$IS_DYNAMIC" \
                        --arg maxSdk "$MAX_SDK" \
                        '{
                            name: $name,
                            normalizedName: $normalized,
                            isDynamic: ($dynamic == "true"),
                            maxSdkVersion: $maxSdk
                        }' >> "$TEMP_PERMS"
                else
                    jq -n \
                        --arg name "$PERM_NAME" \
                        --arg normalized "$NORMALIZED_PERM" \
                        --arg dynamic "$IS_DYNAMIC" \
                        '{
                            name: $name,
                            normalizedName: $normalized,
                            isDynamic: ($dynamic == "true")
                        }' >> "$TEMP_PERMS"
                fi
            fi
        fi
    done <<< "$PERMISSION_LINES"
    
    log "Built permissions data file with normalization"
    
    # Convert JSON Lines to JSON array and create final result
    local result_json=$(jq -s '.' "$TEMP_PERMS" | jq \
        --arg platform "android" \
        --arg source "$ARTIFACT_TYPE" \
        --arg artifact_path "$apk_path" \
        --arg package_name "$PACKAGE_NAME" \
        --arg version_code "$VERSION_CODE" \
        --arg version_name "$VERSION_NAME" \
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
            permissions: .,
            totalPermissions: (. | length),
            dynamicPermissions: (. | map(select(.isDynamic == true)) | length)
        }')
    
    log "Generated final JSON result with dynamic permission tracking $result_json"
    
    echo "$result_json"
}

# Function to extract from AAB (unchanged, but will use updated extract_from_apk)
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
