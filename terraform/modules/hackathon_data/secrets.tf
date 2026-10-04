resource "random_password" "db_master" {
  length  = 32
  special = false
}
