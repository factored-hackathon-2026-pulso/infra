resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-postgres"
  subnet_ids = var.private_subnet_ids
  tags       = var.tags
}
resource "aws_db_instance" "this" {
  identifier                  = "${var.name}-postgres"
  engine                      = "postgres"
  engine_version              = var.postgres_engine_version
  instance_class              = var.instance_class
  allocated_storage           = var.allocated_storage_gib
  max_allocated_storage       = var.max_allocated_storage_gib
  db_name                     = "pulso"
  username                    = "pulso_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [var.database_security_group_id]
  storage_encrypted           = true
  backup_retention_period     = var.backup_retention_days
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = var.skip_final_snapshot
  publicly_accessible         = false
  multi_az                    = var.multi_az
  tags                        = var.tags
}
