# ==========================================
# 1. PROVIDER & VARIABLES
# ==========================================
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

variable "openai_api_key" {
  type      = string
  sensitive = true
}

variable "pinecone_api_key" {
  type      = string
  sensitive = true
}

variable "google_api_key" {
  type      = string
  sensitive = true
}

variable "account_id" {
  type    = string
  default = "640542968817"
}

# ==========================================
# 2. IAM: ECS ROLES
# ==========================================
resource "aws_iam_role" "ecs_execution_role" {
  name = "FridgeAI-Execution-Role-TF1"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec_attach" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ==========================================
# 3. EXISTING ECR REPOS 
# ==========================================
data "aws_ecr_repository" "web" {
  name = "fridgeai-group-web" 
}

data "aws_ecr_repository" "worker" {
  name = "fridgeai-group-worker"
}

# ==========================================
# 4. NETWORKING (VPC & SUBNETS)
# ==========================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "FridgeAI-Group-VPC-TF1"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false 
}

# ==========================================
# 5. SECURITY GROUPS
# ==========================================
resource "aws_security_group" "web_sg" {
  name        = "FridgeAI-Web-SG-TF1"
  description = "Allow inbound traffic to FastAPI on port 8000 and 80"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "worker_sg" {
  name        = "FridgeAI-Worker-SG-TF1"
  description = "Security group for FridgeAI background worker"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "redis_sg" {
  name        = "FridgeAI-Redis-SG-TF1"
  description = "Allow Redis access from Web and Worker"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id, aws_security_group.worker_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 6. ECS CLUSTER & LOGGING
# ==========================================
resource "aws_ecs_cluster" "main" {
  name = "FridgeAI-Group-Cluster-TF1"
}

resource "aws_cloudwatch_log_group" "fridge_logs" {
  name              = "/ecs/fridgeai-group-tf1"
  retention_in_days = 7
}

# ==========================================
# 7. SERVICE DISCOVERY (Cloud Map)
# ==========================================
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "fridgeaigroup-tf1.local"
  vpc  = module.vpc.vpc_id
}

resource "aws_service_discovery_service" "redis" {
  name = "redis"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.main.id
    dns_records {
      ttl  = 60
      type = "A"
    }
  }
}

# ==========================================
# 8. TASK DEFINITIONS
# ==========================================

# WEB TASK
resource "aws_ecs_task_definition" "web" {
  family                   = "fridgeai-group-web-task-tf1"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512" 
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "fridgeai-group-web"
    image     = "${data.aws_ecr_repository.web.repository_url}:latest"
    essential = true
    command   = ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
    environment = [
      { name = "REDIS_URL", value = "redis://redis.fridgeaigroup-tf1.local:6379" },
      { name = "OPENAI_API_KEY", value = var.openai_api_key },
      { name = "PINECONE_API_KEY", value = var.pinecone_api_key },
      { name = "GOOGLE_API_KEY", value = var.google_api_key }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fridge_logs.name
        "awslogs-region"        = "us-east-2"
        "awslogs-stream-prefix" = "web"
      }
    }
  }])
}

# WORKER TASK
resource "aws_ecs_task_definition" "worker" {
  family                   = "fridgeai-group-worker-task-tf1"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512" 
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "fridgeai-group-worker"
    image     = "${data.aws_ecr_repository.worker.repository_url}:latest"
    essential = true
    command   = ["celery", "-A", "app.worker.celery_app", "worker", "--loglevel=info"]
    environment = [
      { name = "REDIS_URL", value = "redis://redis.fridgeaigroup-tf1.local:6379" },
      { name = "OPENAI_API_KEY", value = var.openai_api_key },
      { name = "PINECONE_API_KEY", value = var.pinecone_api_key },
      { name = "GOOGLE_API_KEY", value = var.google_api_key }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fridge_logs.name
        "awslogs-region"        = "us-east-2"
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])
}

# REDIS TASK
resource "aws_ecs_task_definition" "redis" {
  family                   = "fridgeai-group-redis-task-tf1"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256" 
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "fridgeai-group-redis"
    image     = "redis:7-alpine"
    essential = true
    portMappings = [{
      containerPort = 6379
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fridge_logs.name
        "awslogs-region"        = "us-east-2"
        "awslogs-stream-prefix" = "redis"
      }
    }
  }])
}

# ==========================================
# 9. REDIS SERVICE
# ==========================================
resource "aws_ecs_service" "redis" {
  name            = "fridgeai-redis-service-tf1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.redis.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.redis_sg.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.redis.arn
  }
}

# ==========================================
# 10. ALB & WEB SERVICE
# ==========================================
resource "aws_lb" "main" {
  name               = "FridgeAI-Group-ALB-TF1"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_target_group" "web_tg" {
  name        = "FridgeAI-G-TG-TF1"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    path = "/docs"
    port = "8000"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

resource "aws_ecs_service" "web" {
  name            = "fridgeaigroup-web-service-tf1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.public_subnets
    security_groups  = [aws_security_group.web_sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web_tg.arn
    container_name   = "fridgeai-group-web"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.http]
}

# ==========================================
# 11. WORKER SERVICE
# ==========================================
resource "aws_ecs_service" "worker" {
  name            = "fridgeai-worker-service-tf1"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.worker_sg.id]
    assign_public_ip = false
  }
}

# ==========================================
# 12. OUTPUTS
# ==========================================
output "api_endpoint" {
  value       = "http://${aws_lb.main.dns_name}/docs"
  description = "The public URL to access your FridgeAI FastAPI documentation."
}