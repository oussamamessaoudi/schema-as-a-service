#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-validate}"
SUBJECT="${2}"
SCHEMA_PATH="${3}"

# 1. Determine Schema Type from file extension
EXTENSION="${SCHEMA_PATH##*.}"
case "$EXTENSION" in
    avsc)  SCHEMA_TYPE="AVRO" ;;
    json)  SCHEMA_TYPE="JSON" ;;
    proto) SCHEMA_TYPE="PROTOBUF" ;;
    *)     
        MSG="❌ Error: Unsupported file extension .$EXTENSION"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            echo "### 🔍 Verification Error: \`$SUBJECT\`" >> "$GITHUB_STEP_SUMMARY"
            echo "$MSG" >> "$GITHUB_STEP_SUMMARY"
        fi
        echo "$MSG"; exit 1 
        ;;
esac

# 2. Read file and wrap into a standard Confluent REST API JSON payload
CLEAN_STRING=$(jq -Rs . "$SCHEMA_PATH")
PAYLOAD=$(jq -n \
    --arg schema "$CLEAN_STRING" \
    --arg type "$SCHEMA_TYPE" \
    '{schema: ($schema | fromjson), schemaType: $type}')

# 3. Configure optional Basic Authentication header
AUTH_FLAGS=()
if [[ -n "${SCHEMA_REGISTRY_API_KEY:-}" && -n "${SCHEMA_REGISTRY_API_SECRET:-}" ]]; then
    AUTH_FLAGS=(-u "$SCHEMA_REGISTRY_API_KEY:$SCHEMA_REGISTRY_API_SECRET")
fi

# 4. Execute API calls based on operational MODE
if [ "$MODE" = "validate" ]; then
    echo "Validating compatibility for subject: $SUBJECT..."
    
    # ─── LOCAL IDENTICAL CHECK ─────────────────────────────────────────
    # Fetch the latest registered schema version to perform a structural diff
    LATEST_SCHEMA_RESP=$(curl -s "${AUTH_FLAGS[@]}" "$SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions/latest" || echo "{}")
    LATEST_ERROR=$(echo "$LATEST_SCHEMA_RESP" | jq -r '.error_code // empty')
    
    if [ -z "$LATEST_ERROR" ] && [ "$LATEST_SCHEMA_RESP" != "{}" ]; then
        # Minimize and normalize both schemas to ignore whitespace/formatting differences
        LOCAL_NORMALIZED=$(jq -c . "$SCHEMA_PATH" 2>/dev/null || echo "1")
        REMOTE_NORMALIZED=$(echo "$LATEST_SCHEMA_RESP" | jq -c '.schema | fromjson' 2>/dev/null || echo "2")
        
        if [ "$LOCAL_NORMALIZED" = "$REMOTE_NORMALIZED" ]; then
            echo "ℹ️ Local schema is identical to the remote baseline. Skipping processing entirely."
            exit 0
        fi
    fi
    # ───────────────────────────────────────────────────────────────────

    RESPONSE=$(curl -s -X POST "${AUTH_FLAGS[@]}" \
        -H "Content-Type: application/vnd.schemaregistry.v1+json" \
        --data "$PAYLOAD" \
        "$SCHEMA_REGISTRY_URL/compatibility/subjects/$SUBJECT/versions/latest")
    
    # Intercept brand-new schemas (Error code 40402: Subject/Version not found)
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error_code // empty')
    if [ "$ERROR_CODE" = "40402" ]; then
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                echo "### 🔍 Verification: \`$SUBJECT\`"
                echo "- **File:** \`$SCHEMA_PATH\`"
                echo "ℹ️ **Notice:** Subject does not exist yet. Bypassing validation for initial registration."
            } >> "$GITHUB_STEP_SUMMARY"
        fi
        echo "Subject does not exist yet. Bypassing validation."
        exit 0
    fi

    IS_COMPATIBLE=$(echo "$RESPONSE" | jq -r '.isCompatible // .is_compatible // false')

    # ─── REAL COMPATIBILITY FAILURE DETECTED ───────────────────────────
    if [ "$IS_COMPATIBLE" != "true" ]; then
        COMPAT_ERRORS=$(echo "$RESPONSE" | jq -c -r '.messages // [.message] | join(", ")')
        echo "Incompatible changes found: ${COMPAT_ERRORS}" >&2

        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                echo "### 🔍 Verification: \`$SUBJECT\`"
                echo "- **File:** \`$SCHEMA_PATH\`"
                echo "❌ **Result:** Schema compatibility check failed!"
                echo "#### Registry Error Details:"
                echo "\`\`\`json"
                echo "$RESPONSE" | jq .
                echo "\`\`\`"
            } >> "$GITHUB_STEP_SUMMARY"
        fi
        echo "Error: Schema compatibility check failed!"
        echo "$RESPONSE"
        exit 1
    fi
    
    # ─── SUCCESSFUL EVOLUTION (COMPATIBLE CHANGES INTRODUCED) ──────────
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "### 🔍 Verification: \`$SUBJECT\`"
            echo "- **File:** \`$SCHEMA_PATH\`"
            echo "✅ **Result:** Schema is fully compatible."
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "Schema is compatible."

elif [ "$MODE" = "push" ]; then
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "### 🚀 Deployment: \`$SUBJECT\`"
            echo "- **File:** \`$SCHEMA_PATH\`"
        } >> "$GITHUB_STEP_SUMMARY"
    fi

    echo "Registering new version for subject: $SUBJECT..."
    RESPONSE=$(curl -s -X POST "${AUTH_FLAGS[@]}" \
        -H "Content-Type: application/vnd.schemaregistry.v1+json" \
        --data "$PAYLOAD" \
        "$SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions")
    
    SCHEMA_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    if [ -z "$SCHEMA_ID" ]; then
        REG_ERROR=$(echo "$RESPONSE" | jq -c -r '.message // "Unknown registration error"')
        echo "Registration failed: ${REG_ERROR}" >&2

        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                echo "❌ **Result:** Schema registration failed!"
                echo "#### Registry Error Details:"
                echo "\`\`\`json"
                echo "$RESPONSE" | jq .
                echo "\`\`\`"
            } >> "$GITHUB_STEP_SUMMARY"
        fi
        echo "Error: Registration failed!"
        echo "$RESPONSE"
        exit 1
    fi
    
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "✅ **Result:** Registered successfully. Assigned ID: \`$SCHEMA_ID\`" >> "$GITHUB_STEP_SUMMARY"
    echo "Successfully registered schema version. ID: $SCHEMA_ID"
fi