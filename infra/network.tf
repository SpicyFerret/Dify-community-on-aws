data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-igw"
  }
}

# Subnet publica: usada apenas para EGRESS (Cloudflare Tunnel e' outbound-only).
# Recebe IP publico dinamico para sair pela internet sem custo de NAT Gateway.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Sem nenhuma regra de inbound vinda da internet.
# A unica porta de entrada (SSH 22) e' liberada apenas para o CIDR da VPC,
# por onde chega o trafego do WARP via warp-routing do cloudflared.
resource "aws_security_group" "instance" {
  name        = "${local.name}-instance"
  description = "Dify instance - egress only + SSH apenas de dentro da VPC (WARP)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH via WARP (warp-routing) - apenas de dentro da VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Saida liberada (Cloudflare, Docker Hub, updates, S3, etc)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-instance"
  }
}
