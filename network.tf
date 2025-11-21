# --- 1. VPC (Віртуальна приватна хмара) ---
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# --- 2. Internet Gateway (IGW) ---
# Дозволяє трафіку йти з VPC в Інтернет
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# --- 3. Public Subnets (для ALB та Fargate) ---
# Створюємо дві підмережі у різних зонах доступності для високої доступності
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index) # 10.0.0.0/24 та 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # Дозволяє Fargate отримувати публічні IP

  tags = {
    Name = "${var.project_name}-public-subnet-${count.index + 1}"
  }
}

# --- 4. Route Table (Таблиця маршрутизації) ---
# Направляє трафік з публічних підмереж через IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

# Асоціація Route Table з публічними підмережами
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Data Source: Availability Zones ---
# Отримуємо доступні зони доступності в регіоні eu-central-1
data "aws_availability_zones" "available" {
  state = "available"
}