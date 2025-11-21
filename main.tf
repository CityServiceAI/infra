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
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id = aws_vpc.main.id 

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
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id = aws_vpc.main.id

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
  internal           = false
  load_balancer_type = "application"
  # ПОСИЛАННЯ НА СТВОРЕНІ ПУБЛІЧНІ ПІДМЕРЕЖІ
  subnets            = [for s in aws_subnet.public : s.id] 
  security_groups    = [aws_security_group.alb_sg.id]
}

# Target Group (де ALB направляє трафік)
resource "aws_lb_target_group" "main" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/" 
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
locals {
  aws_account_id = "439525862286"  // ВАШ AWS Account ID
  aws_region     = "eu-central-1"   // Ваш регіон
  secret_name    = "assistant-orchestrator/llm_api_key" // Назва секрету, який ви створили
  llm_api_url    = "https://codemie.lab.epam.com/llms"
  secret_key_name = "LLM_PROXY_SERVICE_API_KEY"
}

resource "aws_iam_policy" "ecs_secrets_policy" {
  name        = "${var.project_name}-secrets-policy"
  description = "Дозволяє ECS Task Execution Role читати секрет API ключа."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        // Дозвіл на читання конкретного секрету (використовуємо -* для версіонування)
        Resource = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:${local.secret_name}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        // Дозвіл на використання стандартного ключа KMS для шифрування секрету
        Resource = "*" 
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${local.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

// <-- ЗМІНИ ДЛЯ SECRETS MANAGER (Прив'язка політики до ролі)
resource "aws_iam_role_policy_attachment" "ecs_secrets_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_policy.arn
}


# --- 5. ECS Task Definition (Контейнер) ---
resource "aws_ecs_task_definition" "main" {
  family                   = var.project_name
  cpu                      = 256
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  
  container_definitions = jsonencode([
    {
      name      = var.project_name
      // ВИКОРИСТОВУЄМО ПОВНИЙ URI З ДИГЕСТОМ
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
          "awslogs-group"         = aws_cloudwatch_log_group.main.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      
      // <-- ЗМІНИ ДЛЯ SECRETS MANAGER (Блок інжекції секрету)
      secrets = [
        {
          name      = "LLM_PROXY_SERVICE_API_KEY" // Назва змінної середовища в контейнері
          // Повний ARN секрету
          valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:${local.secret_name}"
        }
      ]
      
      // Налаштування URL для API проксі
      environment = [
        {
          name  = "LLM_PROXY_SERVICE_API_URL"
          value = local.llm_api_url
        }
      ]
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
  desired_count   = var.desired_container_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_task_sg.id]
    # ПОСИЛАННЯ НА СТВОРЕНІ ПУБЛІЧНІ ПІДМЕРЕЖІ
    subnets         = [for s in aws_subnet.public : s.id]
    assign_public_ip = true
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