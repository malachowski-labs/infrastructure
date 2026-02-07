#!/bin/bash
# Test script to verify Workload Identity Federation fix

set -e

echo "================================"
echo "Workload Identity Fix Verification"
echo "================================"
echo ""

# Test 1: Check if anonymous auth is enabled
echo "1. Checking API server anonymous-auth flag..."
ANON_AUTH=$(kubectl get pod -n kube-system -l component=kube-apiserver -o yaml | grep "anonymous-auth" || echo "not found")
if echo "$ANON_AUTH" | grep -q "anonymous-auth=true"; then
    echo "   ✓ Anonymous auth is ENABLED"
else
    echo "   ✗ Anonymous auth is DISABLED or not found"
    echo "   Found: $ANON_AUTH"
fi
echo ""

# Test 2: Check ClusterRoleBinding
echo "2. Checking ClusterRoleBinding for anonymous access..."
if kubectl get clusterrolebinding system:service-account-issuer-discovery-anonymous &>/dev/null; then
    echo "   ✓ ClusterRoleBinding exists"
else
    echo "   ✗ ClusterRoleBinding not found"
fi
echo ""

# Test 3: Test JWKS endpoint from inside cluster (anonymous)
echo "3. Testing JWKS endpoint from inside cluster (anonymous)..."
JWKS_INTERNAL=$(kubectl run test-jwks --rm -i --restart=Never --image=curlimages/curl:latest -- curl -sSk https://kubernetes.default.svc.cluster.local/openid/v1/jwks 2>&1 || true)
if echo "$JWKS_INTERNAL" | grep -q '"keys"'; then
    echo "   ✓ JWKS endpoint accessible from inside cluster"
else
    echo "   ✗ JWKS endpoint NOT accessible from inside cluster"
    echo "   Response: $JWKS_INTERNAL"
fi
echo ""

# Test 4: Test OIDC discovery endpoint (public)
echo "4. Testing OIDC discovery endpoint (public)..."
OIDC_CONFIG=$(curl -s https://oidc.malachowski.me/.well-known/openid-configuration)
if echo "$OIDC_CONFIG" | grep -q '"issuer"'; then
    echo "   ✓ OIDC discovery endpoint accessible"
else
    echo "   ✗ OIDC discovery endpoint NOT accessible"
fi
echo ""

# Test 5: Test JWKS endpoint (public via nginx proxy)
echo "5. Testing JWKS endpoint (public via nginx proxy)..."
JWKS_PUBLIC=$(curl -s https://oidc.malachowski.me/openid/v1/jwks)
if echo "$JWKS_PUBLIC" | grep -q '"keys"'; then
    echo "   ✓ JWKS endpoint accessible via public URL"
    echo "   Keys found: $(echo "$JWKS_PUBLIC" | jq -r '.keys | length')"
else
    echo "   ✗ JWKS endpoint NOT accessible via public URL"
    echo "   Response: $JWKS_PUBLIC"
fi
echo ""

# Test 6: Check ClusterSecretStore status
echo "6. Checking ClusterSecretStore status..."
CSS_STATUS=$(kubectl get clustersecretstore gcpsm-secret-store -o jsonpath='{.status.conditions[0].reason}' 2>&1 || echo "not found")
if [ "$CSS_STATUS" = "Valid" ]; then
    echo "   ✓ ClusterSecretStore is READY"
elif [ "$CSS_STATUS" = "InvalidProviderConfig" ]; then
    echo "   ⚠ ClusterSecretStore is still INVALID"
    echo "   Message: $(kubectl get clustersecretstore gcpsm-secret-store -o jsonpath='{.status.conditions[0].message}')"
else
    echo "   ℹ ClusterSecretStore status: $CSS_STATUS"
fi
echo ""

# Test 7: Check External Secrets Operator logs
echo "7. Checking External Secrets Operator recent logs..."
ESO_LOGS=$(kubectl logs -n external-secrets deployment/external-secrets --tail=20 --since=5m 2>&1 | grep -i "error\|clustersecretstore" | tail -5 || echo "No recent errors")
if [ "$ESO_LOGS" = "No recent errors" ]; then
    echo "   ✓ No recent errors in ESO logs"
else
    echo "   Recent log entries:"
    echo "$ESO_LOGS" | sed 's/^/   /'
fi
echo ""

echo "================================"
echo "Verification Complete"
echo "================================"
echo ""
echo "If all tests pass, your Workload Identity Federation is configured correctly!"
echo "If tests fail, wait a few minutes for the API server to fully restart and run this script again."
