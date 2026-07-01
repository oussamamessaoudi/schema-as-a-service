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
    *)     echo "Error: Unsupported file extension .$EXTENSION"; exit 1 ;;
esac

# 2. Read file and wrap into a standard Confluent REST API JSON payload
# Uses jq -Rs to handle escaping nested quotes and newlines safely
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
    
    # Confluent API returns {"isCompatible":true/false}
    IS_COMPATIBLE=$(echo "$RESPONSE" | jq -r '.isCompatible // false')
    if [ "$IS_COMPATIBLE" != "true" ]; then
        echo "Error: Schema compatibility check failed!"
        echo "$RESPONSE"
        exit 1
    fi
    echo "Schema is compatible."

elif [ "$MODE" = "push" ]; then
    echo "Registering new version for subject: $SUBJECT..."
    RESPONSE=$(curl -s -X POST "${AUTH_FLAGS[@]}" \
        -H "Content-Type: application/vnd.schemaregistry.v1+json" \
        --data "$PAYLOAD" \
        "$SCHEMA_REGISTRY_URL/subjects/$SUBJECT/versions")
    
    # Successful registration returns a schema identifier {"id": 10001}
    SCHEMA_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
    if [ -z "$SCHEMA_ID" ]; then
        echo "Error: Registration failed!"
        echo "$RESPONSE"
        exit 1
    fi
    echo "Successfully registered schema version. ID: $SCHEMA_ID"
fi