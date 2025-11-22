terraform {
  required_version = "~> 1.5.7"

  # --- КОНФІГУРАЦІЯ BACKEND (Критично важливо) ---
  # Зберігає стан Terraform у S3, що необхідно для спільної роботи та надійності
  backend "s3" {
    bucket  = "hakaton-vikings-bucket"
    key     = "fargate/terraform.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.22.1"
    }
  }
}

# --- КОНФІГУРАЦІЯ ПРОВАЙДЕРА AWS ---
provider "aws" {
  region = "us-east-1"
}

# =========================================================
#             1. Джерела Даних (ECR Image URIs)
# =========================================================

# Отримуємо URI останнього образу для БЕКЕНДУ
data "aws_ecr_repository" "backend_repo" {
  name = var.ecr_repository_name
  region = "eu-central-1"
}

data "aws_ecr_image" "latest_backend_image" {
  repository_name = var.ecr_repository_name
  image_tag       = "latest"
  region = "eu-central-1"
}

# Отримуємо URI останнього образу для ФРОНТЕНДУ
data "aws_ecr_repository" "frontend_repo" {
  name = var.frontend_ecr_repository_name
  region = "eu-central-1"
}

data "aws_ecr_image" "latest_frontend_image" {
  repository_name = var.frontend_ecr_repository_name
  image_tag       = "latest"
  region = "eu-central-1"
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
  name = "${var.project_name}-alb-sg"
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
  name = "${var.project_name}-task-sg"
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id = aws_vpc.main.id

  # Дозвіл для трафіку від ALB до обох контейнерів на будь-який порт
  ingress {
    from_port       = 0 
    to_port         = 65535 
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] 
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
  subnets         = [for s in aws_subnet.public : s.id]
  security_groups = [aws_security_group.alb_sg.id]
}

# Target Group для БЕКЕНДУ (ВИПРАВЛЕНО: перейменовано з 'main' на 'backend' для ясності)
resource "aws_lb_target_group" "backend" {
  name     = "${var.project_name}-backend-tg"
  # ВИПРАВЛЕНО: Використовуємо спеціальний порт для бекенду
  port     = var.backend_container_port
  protocol = "HTTP"
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Target Group для ФРОНТЕНДУ
resource "aws_lb_target_group" "frontend" {
  name     = "${var.project_name}-frontend-tg"
  port     = var.frontend_container_port
  protocol = "HTTP"
  # ПОСИЛАННЯ НА СТВОРЕНИЙ VPC
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/" # Перевірка кореневого шляху для фронтенду
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener (слухає порт 80 та маршрутизує трафік)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  # ДІЯ ЗА ЗАМОВЧУВАННЯМ: Весь трафік іде на ФРОНТЕНД
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# Правило для перенаправлення API-трафіку на БЕКЕНД
resource "aws_lb_listener_rule" "backend_api_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100 # Нижчий пріоритет, ніж default

  action {
    type             = "forward"
    # ВИПРАВЛЕНО: Посилання на aws_lb_target_group.backend
    target_group_arn = aws_lb_target_group.backend.arn 
  }
  

  condition {
    path_pattern {
      values = ["/api/*"]
    }
    
  }
  transform {
    type = "url-rewrite"
    url_rewrite_config {
      rewrite {
        regex   = "^/api/conversations/?(.*)$"
        replace = "/conversations/$1"
      }
    }
  }
  
 
}

locals {
  aws_account_id                = "439525862286" 
  aws_region                    = "us-east-1" 
  llm_api_url                   = "https://codemie.lab.epam.com/llms"
  aws_bedrock_guardrail_id      = "d7zfe6q3lq6s"
  aws_bedrock_guardrail_version = "DRAFT"
  # ВИДАЛЕНО: Зайві локальні змінні
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
        # Дозвіл на читання конкретного секрету (використовуємо -* для версіонування)
        Resource = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
        ]
        # Дозвіл на використання стандартного ключа KMS для шифрування секрету
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${local.aws_region}.amazonaws.com"
          }
        }
      },
      {
      "Effect": "Allow",
      "Action": [
        "bedrock:*"
      ],
      "Resource": "*"
    }
    ]
  })
}

# Прив'язка політики до ролі
resource "aws_iam_role_policy_attachment" "ecs_secrets_attach" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_policy.arn
}


# =========================================================
#                   5. ECS Task Definitions
# =========================================================

# Task Definition для БЕКЕНДУ (ВИПРАВЛЕНО: перейменовано з 'main' на 'backend')
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-backend" # ВИПРАВЛЕНО: Додано суфікс для ясності
  cpu                      = 256
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn              = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name = "${var.project_name}-backend" 
      image     = data.aws_ecr_image.latest_backend_image.image_uri
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          # ВИПРАВЛЕНО: Використовуємо спеціальну змінну для порту бекенду
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          # ВИПРАВЛЕНО: Посилання на aws_cloudwatch_log_group.backend
          "awslogs-group"         = aws_cloudwatch_log_group.backend.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "ecs-backend"
        }
      }

      # Інжекція секретів
      secrets = [
        {
          name      = "LLM_PROXY_SERVICE_API_KEY"
          valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/llm_api_key"
        },
        {
          name      = "LANGFUSE_SECRET_KEY"
          valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/langfuse_secret_key"
        },
        {
          name      = "LANGFUSE_PUBLIC_KEY"
          valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/langfuse_public_key"
        }
        # {
        #   name      = "AWS_ACCESS_KEY_ID"
        #   valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/aws_access_key_id"
        # },
        # {
        #   name      = "AWS_SECRET_ACCESS_KEY"
        #   valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/aws_secret_access_key"
        # },
        # {
        #   name      = "AWS_SESSION_TOKEN"
        #   valueFrom = "arn:aws:secretsmanager:${local.aws_region}:${local.aws_account_id}:secret:assistant-orchestrator/aws_session_token"
        # }
      ]

      # Налаштування URL для API проксі
      environment = [
        {
          name  = "LLM_PROXY_SERVICE_API_URL"
          value = local.llm_api_url
        },
        {
          name  = "AWS_BEDROCK_GUARDRAIL_VERSION"
          value = local.aws_bedrock_guardrail_version
        },
        {
          name  = "AWS_BEDROCK_GUARDRAIL_ID"
          value = local.aws_bedrock_guardrail_id
        }
      ]
    }
  ])
}

# Task Definition для ФРОНТЕНДУ
resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project_name}-frontend"
  cpu                      = 256
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name = "${var.project_name}-frontend"
      image     = data.aws_ecr_image.latest_frontend_image.image_uri
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = var.frontend_container_port
          hostPort      = var.frontend_container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.frontend.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "ecs-frontend"
        }
      }
            # Секція environment тут може містити змінні для конфігурації фронтенду (наприклад, VITE_API_BASE_URL)

       environment = [
      {
        name  = "API_BASE_URL"
        value =  "http://${aws_lb.main.dns_name}"
      },
      {
        name = "VERBOSE"
        value = "1"
      }
    ]
    }
  ])
}

# CloudWatch Log Group для логів БЕКЕНДУ
resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project_name}-backend"
  retention_in_days = 7
}

# CloudWatch Log Group для логів ФРОНТЕНДУ
resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${var.project_name}-frontend"
  retention_in_days = 7
}

# =========================================================
#                   7. ECS Services
# =========================================================

# ECS Service для БЕКЕНДУ
resource "aws_ecs_service" "backend" {
  name            = "${var.project_name}-backend-service"
  cluster         = aws_ecs_cluster.main.id
  # ВИПРАВЛЕНО: Посилання на aws_ecs_task_definition.backend
  task_definition = aws_ecs_task_definition.backend.arn 
  desired_count   = var.desired_container_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_task_sg.id]
    # ПОСИЛАННЯ НА СТВОРЕНІ ПУБЛІЧНІ ПІДМЕРЕЖІ
    subnets          = [for s in aws_subnet.public : s.id]
    assign_public_ip = true
  }

  load_balancer {
    # ВИПРАВЛЕНО: Посилання на aws_lb_target_group.backend
    target_group_arn = aws_lb_target_group.backend.arn 
    # ВИПРАВЛЕНО: Ім'я контейнера
    container_name   = "${var.project_name}-backend" 
    # ВИПРАВЛЕНО: Порт контейнера
    container_port   = var.backend_container_port
  }

  depends_on = [
    aws_lb_listener.http,
    aws_lb_listener_rule.backend_api_rule
  ]
}

# ECS Service для ФРОНТЕНДУ
resource "aws_ecs_service" "frontend" {
  name            = "${var.project_name}-frontend-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = var.desired_container_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_task_sg.id]
    # ПОСИЛАННЯ НА СТВОРЕНІ ПУБЛІЧНІ ПІДМЕРЕЖІ
    subnets          = [for s in aws_subnet.public : s.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "${var.project_name}-frontend"
    container_port   = var.frontend_container_port
  }

  depends_on = [
    aws_lb_listener.http
  ]
}