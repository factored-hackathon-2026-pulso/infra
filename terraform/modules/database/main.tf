resource "aws_db_subnet_group" "this" { name_prefix = "${var.tags["Environment"]}-pulso-"; subnet_ids = var.private_subnet_ids; tags = var.tags }
resource "aws_db_instance" "this" {
  identifier_prefix = "${var.tags["Environment"]}-pulso-"; engine = var.database_engine; instance_class = var.instance_class; allocated_storage = 20; max_allocated_storage = 100; db_name = "pulso"; username = "pulso_admin"; manage_master_user_password = true
  db_subnet_group_name = aws_db_subnet_group.this.name; vpc_security_group_ids = var.security_group_ids; backup_retention_period = var.backup_retention_days; deletion_protection = var.deletion_protection; skip_final_snapshot = var.skip_final_snapshot; storage_encrypted = true; publicly_accessible = false; multi_az = var.multi_az; tags = var.tags
}
