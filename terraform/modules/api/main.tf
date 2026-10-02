resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-api"
  protocol_type = "HTTP"
  tags          = var.tags
}
resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
  access_log_settings {
    destination_arn = var.access_log_group_arn
    format = jsonencode({ requestId = "$context.requestId", status = "$context.status"
    })
  }
  tags = var.tags
}
