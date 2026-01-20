#!/bin/bash
# Helper script to use ODF templates
# Usage: ./odf/scripts/apply-template.sh <template-name> [namespace]

set -e

TEMPLATE_NAME="${1}"
NAMESPACE="${2:-default}"
TEMPLATE_DIR="odf/templates"

if [ -z "$TEMPLATE_NAME" ]; then
    echo "Usage: $0 <template-name> [namespace]"
    echo ""
    echo "Available templates:"
    ls -1 ${TEMPLATE_DIR}/*.template 2>/dev/null | sed 's|.*/||' | sed 's|\.template||' || echo "No templates found"
    exit 1
fi

TEMPLATE_FILE="${TEMPLATE_DIR}/${TEMPLATE_NAME}.template"

if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "❌ Template not found: $TEMPLATE_FILE"
    exit 1
fi

echo "📋 Applying template: $TEMPLATE_NAME"
echo "📁 Namespace: $NAMESPACE"
echo ""

# Export default namespace
export NAMESPACE

# Check required variables
case "$TEMPLATE_NAME" in
    pvc-rbd|pvc-cephfs)
        if [ -z "$PVC_NAME" ]; then
            echo "⚠️  Warning: PVC_NAME not set"
            echo "   Set with: export PVC_NAME=my-pvc"
        fi
        if [ -z "$STORAGE_SIZE" ]; then
            echo "⚠️  Warning: STORAGE_SIZE not set"
            echo "   Set with: export STORAGE_SIZE=10Gi"
        fi
        ;;
    statefulset-rbd)
        if [ -z "$APP_NAME" ] || [ -z "$IMAGE" ]; then
            echo "⚠️  Warning: Required variables not set"
            echo "   Set with: export APP_NAME=myapp IMAGE=myimage:tag"
        fi
        ;;
esac

# Apply template
if command -v envsubst &> /dev/null; then
    envsubst < "$TEMPLATE_FILE" | oc apply -f -
    echo ""
    echo "✅ Template applied successfully"
else
    echo "❌ envsubst not found. Please install gettext package"
    echo "   macOS: brew install gettext"
    echo "   Linux: apt-get install gettext-base"
    exit 1
fi

