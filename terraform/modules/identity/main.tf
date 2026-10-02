data "aws_iam_policy_document" "task_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] } }
}
resource "aws_iam_role" "task" { name_prefix = "${var.tags["Environment"]}-pulso-task-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role" "execution" { name_prefix = "${var.tags["Environment"]}-pulso-exec-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role_policy_attachment" "execution" { role = aws_iam_role.execution.name; policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }
resource "aws_iam_role_policy" "task" { name = "least-privilege-placeholder"; role = aws_iam_role.task.id; policy = jsonencode({ Version = "2012-10-17", Statement = [] }) }
