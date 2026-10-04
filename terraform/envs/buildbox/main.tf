provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Purpose   = "buildbox"
      Ephemeral = "true"
    }
  }
}

# The account's default VPC and a default public subnet: no dependency on any prod root.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

module "buildbox" {
  source = "../../modules/buildbox"

  region         = var.region
  vpc_id         = data.aws_vpc.default.id
  subnet_id      = sort(data.aws_subnets.default.ids)[0]
  instance_type  = var.instance_type
  data_volume_gb = var.data_volume_gb
}
