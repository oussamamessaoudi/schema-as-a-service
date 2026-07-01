#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-validate}"
SUBJECT="${2}"
SCHEMA_PATH="${3}"

# Initialize Github Step Summary headers if running inside a GitHub Runner
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### $([ "$MODE" = "validate" ] && echo "🔍 Verification" || echo "🚀 Deployment"): \`$SUBJECT\`"
        echo "- **File:** \`$SCHEMA_PATH\`"
    } >> "$GITHUB_STEP_SUMMARY"
fi

# 1. Determine Schema Type from file extension
EXTENSION="${SCHEMA_PATH##*.}"
case "$EXTENSION" in
    avsc)  SCHEMA_TYPE="AVRO" ;;
    json)  SCHEMA_TYPE="JSON" ;;
    proto) SCHEMA_TYPE="PROTOBUF" ;;
    *)     
        MSG="❌ Error: Unsupported file extension .$EXTENSION"
        [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$MSG" >> "$GITHUB_STEP_SUMMARY"
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
    RESPONSE=$(curl -s -X POST "${AUTH_FLAGS[@]}" \
        -H "Content-Type: application/vnd.schemaregistry.v1+json" \
        --data "$PAYLOAD" \
        "$SCHEMA_REGISTRY_URL/compatibility/subjects/$SUBJECT/versions/latest")
    
    # Intercept brand-new schemas (Error code 40402: Subject/Version not found)
    ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error_code // empty')
    if [ "$ERROR_CODE" = "40402" ]; then
        MSG="ℹ️ **Notice:** Subject does not exist yet. Bypassing validation for initial registration."
        [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$MSG" >> "$GITHUB_STEP_SUMMARY"
        echo "$MSG"
        exit 0
    fi

    # Check both camelCase and snake_case variations for Confluent/Aiven API flexibility
    IS_COMPATIBLE=$(echo "$RESPONSE" | jq -r '.isCompatible // .is_compatible // false')
    if [ "$IS_COMPATIBLE" != "true" ]; then
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
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
    
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "✅ **Result:** Schema is fully compatible." >> "$GITHUB_STEP_SUMMARY"
    echo "Schema is compatible."

elif [ "$MODE" = "push" ]; then
    echo "Registering new version for subject: $SUBJECT..."
    RESPONSE=$(curl -s -X POST "${AUTH_FLAGS[@]}" \
        -H "Content-Type: application/vnd.schemaregistry.v1+json" \
        --data "$PAYLOAD" \
        "$SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions")
    
    SCHEMA_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    if [ -z "$SCHEMA_ID" ]; then
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