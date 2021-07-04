provider "aws" {
  region = var.region
}

resource "aws_ecr_repository" "demo_repo" {
  name = "flash_meeting_repo"
}

resource "aws_ecs_cluster" "demo_cluster" {
  name = "flash_meeting_cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "demo_execution_role" {
  name               = "flash_meeting_execution_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

resource "aws_cloudwatch_log_group" "demo_logs" {
  name = "flash_meeting_logs"
}

resource "aws_ecs_task_definition" "demo_task" {
  family                   = "flash_meeting_task"
  container_definitions    = <<DEFINITION
  [
    {
      "name": "flash_meeting_task",
      "image": "${aws_ecr_repository.demo_repo.repository_url}",
      "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-region" : "us-east-1",
                    "awslogs-group" : "flash_meeting_logs",
                    "awslogs-stream-prefix" : "demo"
                }
            },
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our container requires
  cpu                      = 256         # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.demo_execution_role.arn
}

resource "aws_iam_role_policy_attachment" "demo_execution_role_policy" {
  role       = aws_iam_role.demo_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_security_group" "demo_load_balancer_security_group" {
  name = "demo_load_balancer"
  ingress {
    from_port   = 80 # Allowing traffic in from port 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
  }

  egress {
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

resource "aws_security_group" "demo_service_security_group" {
  name = "demo_service"
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = [aws_security_group.demo_load_balancer_security_group.id]
  }

  egress {
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

# Providing a reference to our default VPC
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "${var.region}a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "${var.region}b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "${var.region}c"
}

resource "aws_alb" "demo_application_load_balancer" {
  name               = "flash-meeting-alb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    aws_default_subnet.default_subnet_a.id,
    aws_default_subnet.default_subnet_b.id,
    aws_default_subnet.default_subnet_c.id
  ]
  # Referencing the security group
  security_groups = [aws_security_group.demo_load_balancer_security_group.id]
}

resource "aws_lb_target_group" "demo_target_group" {
  name        = "flash-meeting-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
  health_check {
    matcher = "200,301,302"
    path    = "/"
  }
}

resource "aws_lb_listener" "demo_listener" {
  load_balancer_arn = aws_alb.demo_application_load_balancer.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.demo_target_group.arn # Referencing our tagrte group
  }
}

resource "aws_ecs_service" "demo_service" {
  depends_on = [
    aws_alb.demo_application_load_balancer
  ]
  name            = "flash-meeting-service"               # Naming our first service
  cluster         = aws_ecs_cluster.demo_cluster.id       # Referencing our created Cluster
  task_definition = aws_ecs_task_definition.demo_task.arn # Referencing the task our service will spin up
  launch_type     = "FARGATE"
  desired_count   = 1 # Setting the number of containers we want deployed to 1

  load_balancer {
    target_group_arn = aws_lb_target_group.demo_target_group.arn # Referencing our target group
    container_name   = aws_ecs_task_definition.demo_task.family
    container_port   = 3000 # Specifying the container port
  }

  network_configuration {
    subnets = [
      aws_default_subnet.default_subnet_a.id,
      aws_default_subnet.default_subnet_b.id,
      aws_default_subnet.default_subnet_c.id
    ]
    assign_public_ip = true # Providing our containers with public IPs
    security_groups  = [aws_security_group.demo_service_security_group.id]
  }
}

terraform {
  backend "s3" {
    bucket               = "terraform-tfstate-00000001"
    key                  = "terraform.tfstate"
    region               = "us-east-1"
    workspace_key_prefix = "tf-state"
  }
}


# resource "aws_s3_bucket" "bucket_teste_cloud_front" {
#   bucket = "cloud-front-teste00000000004"
#   acl    = "private"

#   website {
#     index_document = "index.html"
#     error_document = "index.html"
#   }
# }
