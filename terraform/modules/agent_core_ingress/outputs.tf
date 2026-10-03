output "target_group_arn" { value = aws_lb_target_group.this.arn }
output "target_group_arn_suffix" { value = aws_lb_target_group.this.arn_suffix }
output "load_balancer_arn" { value = aws_lb.this.arn }
output "load_balancer_arn_suffix" { value = aws_lb.this.arn_suffix }
output "dns_name" { value = aws_lb.this.dns_name }
output "listener_arn" { value = aws_lb_listener.https.arn }
