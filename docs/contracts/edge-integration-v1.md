# Edge integration contract v1

## Status

**Deferred; non-deploying.** Neither Terraform environment creates an HTTP API
Gateway resource until this contract is completed and approved.

## Why

API Gateway HTTP APIs are public by default and do not support security-group
attachment. A log stage with no authenticated route integration is therefore
not a safe placeholder: it creates a public control-plane surface without an
enforceable workload boundary.

## Required approval inputs

An implementation slice must supply all of the following, versioned with the
engine release it exposes:

1. An engine listener contract: protocol, health path, request limits and an
   immutable image/version target.
2. One enforceable ingress decision: an approved authorizer for every route,
   or an approved private ingress topology. The decision must be represented by
   Terraform resources and structural regression tests, not prose alone.
3. Route-to-integration mappings, least-privilege invocation permissions and
   access-log/metric dimensions that do not log PII.
4. An explicit denial behavior for unauthenticated, unauthorized and unknown
   routes, plus an integration/E2E test against the selected sandbox boundary.

Until then, the engine remains private in its workload security group. The
edge security group, HTTPS ingress/egress rules and workload-from-edge rule
are also absent: retaining them would pre-authorize a public attachment before
the edge contract exists.
