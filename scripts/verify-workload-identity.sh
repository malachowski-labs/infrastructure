#!/bin/bash

# Quick verification script for External Secrets Operator with Workload Identity

set -e

echo "🔍 External Secrets Operator - Workload Identity Verification"
echo "=============================================================="
echo ""

# Check OIDC Discovery Service
echo "1️⃣ Checking OIDC Discovery Service..."
kubectl get deployment -n oidc-discovery oidc-discovery &>/dev/null && \
  echo "   ✅ OIDC Discovery deployment exists" || \
  echo "   ❌ OIDC Discovery deployment not found"

kubectl get svc -n oidc-discovery oidc-discovery &>/dev/null && \
  echo "   ✅ OIDC Discovery service exists" || \
  echo "   ❌ OIDC Discovery service not found"

kubectl get ingress -n oidc-discovery oidc-discovery &>/dev/null && \
  echo "   ✅ OIDC Discovery ingress exists" || \
  echo "   ❌ OIDC Discovery ingress not found"

echo ""

# Check External Secrets Operator
echo "2️⃣ Checking External Secrets Operator..."
kubectl get deployment -n external-secrets external-secrets &>/dev/null && \
  echo "   ✅ ESO deployment exists" || \
  echo "   ❌ ESO deployment not found"

kubectl get sa -n external-secrets external-secrets-operator &>/dev/null && \
  echo "   ✅ ESO service account exists" || \
  echo "   ❌ ESO service account not found"

# Check service account annotation
SA_ANNOTATION=$(kubectl get sa -n external-secrets external-secrets-operator -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}' 2>/dev/null || echo "")
if [ -n "$SA_ANNOTATION" ]; then
  echo "   ✅ Service account has GCP annotation: $SA_ANNOTATION"
else
  echo "   ❌ Service account missing GCP annotation"
fi

echo ""

# Check ClusterSecretStore
echo "3️⃣ Checking ClusterSecretStore..."
kubectl get clustersecretstore gcpsm-secret-store &>/dev/null && \
  echo "   ✅ ClusterSecretStore exists" || \
  echo "   ❌ ClusterSecretStore not found"

# Check if ClusterSecretStore is ready
CSS_STATUS=$(kubectl get clustersecretstore gcpsm-secret-store -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "$CSS_STATUS" = "True" ]; then
  echo "   ✅ ClusterSecretStore is ready"
else
  echo "   ⚠️  ClusterSecretStore status: $CSS_STATUS"
fi

echo ""

# Check OIDC endpoints
echo "4️⃣ Checking OIDC Endpoints..."
if curl -s -f https://oidc.malachowski.me/.well-known/openid-configuration > /dev/null 2>&1; then
  echo "   ✅ Discovery endpoint accessible"
  ISSUER=$(curl -s https://oidc.malachowski.me/.well-known/openid-configuration | jq -r '.issuer' 2>/dev/null)
  echo "   📝 Issuer: $ISSUER"
else
  echo "   ❌ Discovery endpoint not accessible"
fi

if curl -s -f https://oidc.malachowski.me/openid/v1/jwks > /dev/null 2>&1; then
  echo "   ✅ JWKS endpoint accessible"
  KEY_COUNT=$(curl -s https://oidc.malachowski.me/openid/v1/jwks | jq '.keys | length' 2>/dev/null || echo "0")
  echo "   📝 Number of keys: $KEY_COUNT"
else
  echo "   ❌ JWKS endpoint not accessible"
fi

echo ""

# Check API Server OIDC configuration
echo "5️⃣ Checking API Server OIDC Configuration..."
API_JWKS=$(kubectl get --raw /openid/v1/jwks 2>/dev/null || echo "")
if [ -n "$API_JWKS" ]; then
  echo "   ✅ API server exposes JWKS"
  API_KEY_COUNT=$(echo "$API_JWKS" | jq '.keys | length' 2>/dev/null || echo "0")
  echo "   📝 Number of keys in API server: $API_KEY_COUNT"
else
  echo "   ❌ API server JWKS not accessible"
fi

echo ""

# Check pod status
echo "6️⃣ Checking Pod Status..."
echo "   OIDC Discovery Pods:"
kubectl get pods -n oidc-discovery -l app=oidc-discovery --no-headers 2>/dev/null | awk '{print "     - " $1 ": " $3}' || echo "     ❌ No pods found"

echo "   External Secrets Pods:"
kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets --no-headers 2>/dev/null | awk '{print "     - " $1 ": " $3}' || echo "     ❌ No pods found"

echo ""
echo "=============================================================="
echo "✨ Verification complete!"
echo ""
echo "📚 For more information, see: docs/external-secrets-workload-identity.md"
