# No public API is declared here. HTTP API v2 is public by default and cannot
# use VPC security groups, so declaring an API without an authenticated route
# or approved private ingress would manufacture an unauthenticated endpoint.
# See docs/contracts/edge-integration-v1.md and docs/gaps/OPEN_GAPS.md.
