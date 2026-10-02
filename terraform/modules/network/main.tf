data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  zones     = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
  nat_count = var.nat_strategy == "none" ? 0 : var.nat_strategy == "per_az" ? length(local.zones) : 1
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = "${var.tags["Environment"]}-pulso" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}

resource "aws_subnet" "public" {
  count                   = length(local.zones)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.zones[count.index]
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.tags["Environment"]}-public-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = length(local.zones)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.zones[count.index]
  tags              = merge(var.tags, { Name = "${var.tags["Environment"]}-private-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public" {
  count          = length(local.zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = var.tags
}
resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[var.nat_strategy == "per_az" ? count.index : 0].id
  depends_on    = [aws_internet_gateway.this]
  tags          = var.tags
}
resource "aws_route_table" "private" {
  count  = length(local.zones)
  vpc_id = aws_vpc.this.id
  tags   = var.tags
}
resource "aws_route" "private_nat" {
  count                  = local.nat_count == 0 ? 0 : length(local.zones)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.nat_strategy == "per_az" ? count.index : 0].id
}
resource "aws_route_table_association" "private" {
  count          = length(local.zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
