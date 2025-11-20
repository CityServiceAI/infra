terraform {
  required_version = "~> 1.5.7" # Переконайтеся, що ваша версія Terraform відповідає

  # --- КОНФІГУРАЦІЯ BACKEND (Критично важливо) ---
  # Зберігає стан Terraform у S3, що необхідно для спільної роботи та надійності
  backend "s3" {
    bucket         = "hakaton-vikings-bucket" 
    key            = "fargate/terraform.tfstate"
    region         = "eu-central-1" 
    encrypt        = true
   # dynamodb_table = "terraform-locks" 
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# --- КОНФІГУРАЦІЯ ПРОВАЙДЕРА AWS ---
provider "aws" {
  # Використовуємо регіон, де знаходиться ваш ECR та де ви хочете розгорнути Fargate.
  # Оскільки ви використовували eu-central-1 для ECR, це логічний вибір.
  region = "eu-central-1" 
}

# Використовуйте цей блок, щоб отримати останній образ (Image URI) з ECR
data "aws_ecr_repository" "repo" {
  name = var.ecr_repository_name
}

data "aws_ecr_image" "latest_image" {
  repository_name = var.ecr_repository_name
  image_tag       = "latest" 
}

# --- 1. ECS Cluster ---
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

# --- 2. IAM Roles ---
# Роль для виконання Task (Fargate)
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.project_name}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- 3. Security Groups (Безпека) ---
# SG для Load Balancer (відкритий для світу)
resource "aws_security_group" "alb_sg" {
  name   = "${var.project_name}-alb-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Доступ з будь-якого IP
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SG для Fargate (відкритий тільки для Load Balancer)
resource "aws_security_group" "ecs_task_sg" {
  name   = "${var.project_name}-task-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Доступ лише від ALB
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. Application Load Balancer (ALB) ---
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false # Публічний Load Balancer
  load_balancer_type = "application"
  subnets            = var.public_subnets
  security_groups    = [aws_security_group.alb_sg.id]
}

# Target Group (де ALB направляє трафік)
resource "aws_lb_target_group" "main" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # Для Fargate

  health_check {
    path                = "/" # Замініть на Health Check endpoint, якщо є
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener (слухає порт 80 і перенаправляє на Target Group)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# --- 5. ECS Task Definition (Контейнер) ---
resource "aws_ecs_task_definition" "main" {
  family                   = var.project_name
  cpu                      = "256" # 0.25 vCPU
  memory                   = "512" # 0.5 GB RAM
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  
  # Конфігурація контейнера: використовуємо образ з ECR
  container_definitions = jsonencode([
    {
      name      = var.project_name
      image     = data.aws_ecr_image.latest_image.image_uri
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.main.name
          "awslogs-region" = "eu-central-1" # Замініть на ваш регіон
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# CloudWatch Log Group для логів контейнера
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7
}

# --- 6. ECS Service (Запуск та підтримка) ---
resource "aws_ecs_service" "main" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = 1 # Скільки інстансів контейнера має працювати
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_task_sg.id]
    subnets         = var.public_subnets
    assign_public_ip = true # Для доступу до Інтернету (наприклад, для завантаження даних)
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = var.project_name
    container_port   = var.container_port
  }

  depends_on = [
    aws_lb_listener.http,
  ]
}