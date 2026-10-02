output "edge_security_group_id" {
  value = aws_security_group.edge.id
}
output "workload_security_group_id" {
  value = aws_security_group.workload.id
}
output "database_security_group_id" {
  value = aws_security_group.database.id
}
