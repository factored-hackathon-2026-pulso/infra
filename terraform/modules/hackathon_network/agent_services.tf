# Agent services on the core host (agent-core serve, tool-service). Two paths, both between sibling SGs only:
#   platform -> core:8001  support-platform calls agent-core serve (core-runtime keeps 8000)
#   engine -> core:8001    the engine registers proposals and reads runs through the shared Core (registry/export APIs)
#   engine -> platform:8000 the engine announces proposals and reads evidence
#   core -> platform:8000  agent-core's grant_active asks the platform API whether a delegation is still active
# The platform API is published on the host only for this; CloudFront still reaches the proxy on :80 only.

resource "aws_vpc_security_group_ingress_rule" "agent_from_platform" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.core.id
  description                  = "agent-core serve from support-platform"
  referenced_security_group_id = aws_security_group.platform.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8001
}

resource "aws_vpc_security_group_egress_rule" "platform_to_agent" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.platform.id
  description                  = "agent-core serve on the core host"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8001
}

resource "aws_vpc_security_group_ingress_rule" "platform_api_from_core" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.platform.id
  description                  = "Platform API from agent-core (grant_active)"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "core_to_platform_api" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.core.id
  description                  = "Platform API (grant_active)"
  referenced_security_group_id = aws_security_group.platform.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "agent_from_engine" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.core.id
  description                  = "agent-core serve from the engine"
  referenced_security_group_id = aws_security_group.engine.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8001
}

resource "aws_vpc_security_group_egress_rule" "engine_to_agent" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.engine.id
  description                  = "agent-core serve on the core host"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8001
}

# The engine announces proposals to the platform (POST /api/v1/internal/builder/proposals/announce, bearer) and reads the
# evidence route: engine -> platform API :8000, the same published port agent-core's grant_active uses. Never CloudFront.
resource "aws_vpc_security_group_ingress_rule" "platform_api_from_engine" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.platform.id
  description                  = "Platform API from the engine (announce, evidence)"
  referenced_security_group_id = aws_security_group.engine.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "engine_to_platform_api" {
  count                        = var.agent_services_enabled ? 1 : 0
  security_group_id            = aws_security_group.engine.id
  description                  = "Platform API (announce, evidence)"
  referenced_security_group_id = aws_security_group.platform.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}
