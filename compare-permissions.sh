#!/bin/bash

set -e

VERBOSE=0
ARTIFACTS=()

# Parse arguments
while [[ "$1" != "" ]]; do
    case $1 in
        --verbose ) VERBOSE=1
                    ;;
        * )         ARTIFACTS+=("$1")
                    ;;
    esac
    shift
done

log() {
    if [ "$VERBOSE" -eq 1 ]; then
        echo "[DEBUG] $@" >&2
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASELINE_FILE="$SCRIPT_DIR/baseline-permissions.json"

if [ ${#ARTIFACTS[@]} -eq 0 ]; then
    echo "Usage: $0 [--verbose] <artifact1> [artifact2] ..."
    echo "Supported artifacts: .ipa, .apk, .aab"
    exit 1
fi

log "=== Permission Validation Started ==="
log "Script directory: $SCRIPT_DIR"
log "Baseline file: $BASELINE_FILE"
log "Artifacts to process: ${#ARTIFACTS[@]}"
log "Verbose mode: $VERBOSE"

# Load baseline
BASELINE="{\"ios\":{},\"android\":[]}"
if [ -f "$BASELINE_FILE" ]; then
    BASELINE=$(cat "$BASELINE_FILE")
    echo "✅ Loaded baseline"
    
    if [ "$VERBOSE" -eq 1 ]; then
        IOS_BASELINE_COUNT=$(echo "$BASELINE" | jq '.ios | length')
        ANDROID_BASELINE_COUNT=$(echo "$BASELINE" | jq '.android | length')
        log "Baseline contains: iOS=$IOS_BASELINE_COUNT, Android=$ANDROID_BASELINE_COUNT permissions"
    fi
else
    echo "⚠️  No baseline found, creating initial baseline"
fi

HAS_NEW_PERMISSIONS=false
HAS_REMOVED_PERMISSIONS=false
CURRENT_PERMISSIONS="{\"ios\":{},\"android\":[]}"
NEW_PERMISSIONS_SUMMARY=""
REMOVED_PERMISSIONS_SUMMARY=""

# Function to compare permissions
compare_permissions() {
    local platform="$1"
    local current_perms="$2"
    local baseline_perms="$3"
    
    local new_permissions_found=false
    local removed_permissions_found=false
    local new_perms_list=""
    local removed_perms_list=""
    
    log "Comparing $platform permissions..."
    
    if [ "$platform" = "ios" ]; then
        CURRENT_KEYS=$(echo "$current_perms" | jq -r '.permissions | keys[]' 2>/dev/null | sort)
        BASELINE_KEYS=$(echo "$baseline_perms" | jq -r '.ios | keys[]' 2>/dev/null | sort)
        
        # Find new permissions (in current but not in baseline)
        NEW_PERMS=$(comm -23 <(echo "$CURRENT_KEYS") <(echo "$BASELINE_KEYS"))
        
        # Find removed permissions (in baseline but not in current)
        REMOVED_PERMS=$(comm -13 <(echo "$CURRENT_KEYS") <(echo "$BASELINE_KEYS"))
        
        if [ "$VERBOSE" -eq 1 ]; then
            CURRENT_COUNT=$(echo "$CURRENT_KEYS" | wc -l)
            BASELINE_COUNT=$(echo "$BASELINE_KEYS" | wc -l)
            log "iOS permissions - Current: $CURRENT_COUNT, Baseline: $BASELINE_COUNT"
        fi
        
        # Check for new permissions
        if [ -n "$NEW_PERMS" ]; then
            echo ""
            echo "🚨 NEW iOS PERMISSIONS DETECTED:"
            while IFS= read -r perm; do
                if [ -n "$perm" ]; then
                    DESC=$(echo "$current_perms" | jq -r ".permissions[\"$perm\"]" 2>/dev/null)
                    echo "  + $perm: $DESC"
                    new_perms_list+="$perm, "
                fi
            done <<< "$NEW_PERMS"
            new_permissions_found=true
        fi
        
        # Check for removed permissions
        if [ -n "$REMOVED_PERMS" ]; then
            echo ""
            echo "⚠️  REMOVED iOS PERMISSIONS DETECTED:"
            while IFS= read -r perm; do
                if [ -n "$perm" ]; then
                    DESC=$(echo "$baseline_perms" | jq -r ".ios[\"$perm\"]" 2>/dev/null)
                    echo "  - $perm: $DESC"
                    removed_perms_list+="$perm, "
                fi
            done <<< "$REMOVED_PERMS"
            removed_permissions_found=true
        fi
    
    elif [ "$platform" = "android" ]; then
        CURRENT_PERMS=$(echo "$current_perms" | jq -r '.permissions[].name' 2>/dev/null | sort)
        BASELINE_PERMS=$(echo "$baseline_perms" | jq -r '.android[].name' 2>/dev/null | sort)
        
        # Find new permissions (in current but not in baseline)
        NEW_PERMS=$(comm -23 <(echo "$CURRENT_PERMS") <(echo "$BASELINE_PERMS"))
        
        # Find removed permissions (in baseline but not in current)
        REMOVED_PERMS=$(comm -13 <(echo "$CURRENT_PERMS") <(echo "$BASELINE_PERMS"))
        
        if [ "$VERBOSE" -eq 1 ]; then
            CURRENT_COUNT=$(echo "$CURRENT_PERMS" | wc -l)
            BASELINE_COUNT=$(echo "$BASELINE_PERMS" | wc -l)
            log "Android permissions - Current: $CURRENT_COUNT, Baseline: $BASELINE_COUNT"
        fi
        
        # Check for new permissions
        if [ -n "$NEW_PERMS" ]; then
            echo ""
            echo "🚨 NEW ANDROID PERMISSIONS DETECTED:"
            while IFS= read -r perm; do
                if [ -n "$perm" ]; then
                    echo "  + $perm"
                    new_perms_list+="$perm, "
                fi
            done <<< "$NEW_PERMS"
            new_permissions_found=true
        fi
        
        # Check for removed permissions
        if [ -n "$REMOVED_PERMS" ]; then
            echo ""
            echo "⚠️  REMOVED ANDROID PERMISSIONS DETECTED:"
            while IFS= read -r perm; do
                if [ -n "$perm" ]; then
                    echo "  - $perm"
                    removed_perms_list+="$perm, "
                fi
            done <<< "$REMOVED_PERMS"
            removed_permissions_found=true
        fi
    fi
    
    # Update global summaries
    if [ "$new_permissions_found" = true ]; then
        new_perms_list=${new_perms_list%, }
        
        if [ -n "$NEW_PERMISSIONS_SUMMARY" ]; then
            NEW_PERMISSIONS_SUMMARY="$NEW_PERMISSIONS_SUMMARY; "
        fi
        NEW_PERMISSIONS_SUMMARY="$NEW_PERMISSIONS_SUMMARY$platform: $new_perms_list"
    fi
    
    if [ "$removed_permissions_found" = true ]; then
        removed_perms_list=${removed_perms_list%, }
        
        if [ -n "$REMOVED_PERMISSIONS_SUMMARY" ]; then
            REMOVED_PERMISSIONS_SUMMARY="$REMOVED_PERMISSIONS_SUMMARY; "
        fi
        REMOVED_PERMISSIONS_SUMMARY="$REMOVED_PERMISSIONS_SUMMARY$platform: $removed_perms_list"
    fi
    
    # Return non-zero if any changes detected
    if [ "$new_permissions_found" = true ] || [ "$removed_permissions_found" = true ]; then
        return 1
    fi
    return 0
}

# Process each artifact
for artifact in "${ARTIFACTS[@]}"; do
    if [ ! -f "$artifact" ]; then
        echo "Warning: Artifact not found: $artifact"
        continue
    fi
    
    log "Processing: $artifact"
    log "Artifact size: $(du -h "$artifact" | cut -f1)"
    
    if [[ "$artifact" == *.ipa ]]; then
        log "Extracting iOS permissions..."
        # Pass verbose flag to iOS extraction script
        if [ "$VERBOSE" -eq 1 ]; then
            IOS_PERMS=$("$SCRIPT_DIR/extract-ipa-permissions.sh" --verbose "$artifact")
        else
            IOS_PERMS=$("$SCRIPT_DIR/extract-ipa-permissions.sh" "$artifact")
        fi
        
        if [ $? -ne 0 ]; then
            echo "Error extracting iOS permissions"
            exit 1
        fi
        
        log "iOS permissions extracted successfully"
        CURRENT_PERMISSIONS=$(echo "$CURRENT_PERMISSIONS" | jq ".ios = ($IOS_PERMS | .permissions)")
        
        if ! compare_permissions "ios" "$IOS_PERMS" "$BASELINE"; then
            # Check what type of changes were detected
            if [[ "$NEW_PERMISSIONS_SUMMARY" =~ ios: ]]; then
                HAS_NEW_PERMISSIONS=true
            fi
            if [[ "$REMOVED_PERMISSIONS_SUMMARY" =~ ios: ]]; then
                HAS_REMOVED_PERMISSIONS=true
            fi
        fi
        
    elif [[ "$artifact" == *.apk ]] || [[ "$artifact" == *.aab ]]; then
        log "Extracting Android permissions..."
        # Pass verbose flag to Android extraction script
        if [ "$VERBOSE" -eq 1 ]; then
            ANDROID_PERMS=$("$SCRIPT_DIR/extract-android-permissions.sh" --verbose "$artifact")
        else
            ANDROID_PERMS=$("$SCRIPT_DIR/extract-android-permissions.sh" "$artifact")
        fi
        
        if [ $? -ne 0 ]; then
            echo "Error extracting Android permissions"
            exit 1
        fi
        
        log "Android permissions extracted successfully"
        CURRENT_PERMISSIONS=$(echo "$CURRENT_PERMISSIONS" | jq ".android = ($ANDROID_PERMS | .permissions)")
        
        if ! compare_permissions "android" "$ANDROID_PERMS" "$BASELINE"; then
            # Check what type of changes were detected
            if [[ "$NEW_PERMISSIONS_SUMMARY" =~ android: ]]; then
                HAS_NEW_PERMISSIONS=true
            fi
            if [[ "$REMOVED_PERMISSIONS_SUMMARY" =~ android: ]]; then
                HAS_REMOVED_PERMISSIONS=true
            fi
        fi
    fi
done

# Create baseline if it doesn't exist
if [ ! -f "$BASELINE_FILE" ]; then
    log "Creating new baseline file..."
    NEW_BASELINE=$(jq -n \
        --argjson current "$CURRENT_PERMISSIONS" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" \
        '{
            ios: $current.ios,
            android: $current.android,
            lastUpdated: $timestamp
        }')
    echo "$NEW_BASELINE" > "$BASELINE_FILE"
    echo "Created new baseline"
fi

# Summary
IOS_COUNT=$(echo "$CURRENT_PERMISSIONS" | jq '.ios | length')
ANDROID_COUNT=$(echo "$CURRENT_PERMISSIONS" | jq '.android | length')
echo ""
echo "Current permissions - iOS: $IOS_COUNT, Android: $ANDROID_COUNT"

# Check if any permission changes were detected
if [ "$HAS_NEW_PERMISSIONS" = true ] || [ "$HAS_REMOVED_PERMISSIONS" = true ]; then
    echo ""
    echo "❌ BUILD FAILED: Permission changes detected"
    
    if [ "$HAS_NEW_PERMISSIONS" = true ]; then
        echo "🚨 New permissions: $NEW_PERMISSIONS_SUMMARY"
    fi
    
    if [ "$HAS_REMOVED_PERMISSIONS" = true ]; then
        echo "⚠️  Removed permissions: $REMOVED_PERMISSIONS_SUMMARY"
    fi
    
    echo ""
    echo "📋 To approve changes:"
    echo "   1. Review permission changes above"
    echo "   2. Update baseline: ./update-baseline.sh"
    echo "   3. Create PR with justification for permission changes in 'native-permissions-validator' repo"
    exit 1
else
    echo "✅ No permission changes detected"
    log "Permission validation completed successfully"
    exit 0
fi
