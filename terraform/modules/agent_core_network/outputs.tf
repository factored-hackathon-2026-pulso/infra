output "alb_security_group_id" { value = aws_security_group.alb.id }
output "service_security_group_id" { value = aws_security_group.service.id }
output "proxy_security_group_id" { value = aws_security_group.proxy.id }
output "database_security_group_id" { value = aws_security_group.database.id }
