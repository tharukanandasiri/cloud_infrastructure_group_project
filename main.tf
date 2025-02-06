terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

backend "s3" {
  bucket         = "ci-architects"
  key            = "terraform/state.tfstate"
  region         = "us-east-1" 
  dynamodb_table = "terraform-state-locking"
}
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
    tags = {
      Name = "main-vpc"
    }
}

resource "aws_internet_gateway" "gw" {
    vpc_id = aws_vpc.main.id
    tags = {
      Name = "main-igw"
    }
}

resource "aws_subnet" "public_subnet_1" {
    vpc_id = aws_vpc.main.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "us-east-1a"
     tags = {
       Name = "public-subnet-1"
     }
}

resource "aws_subnet" "public_subnet_2" {
    vpc_id = aws_vpc.main.id
    cidr_block = "10.0.2.0/24"
    availability_zone = "us-east-1b"
     tags = {
       Name = "public-subnet-2"
     }
}

resource "aws_route_table" "public_rt" {
    vpc_id = aws_vpc.main.id
     tags = {
       Name = "public-rt"
     }
}

resource "aws_route" "public_route" {
    route_table_id = aws_route_table.public_rt.id
    destination_cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
}

 resource "aws_route_table_association" "public_1_assoc" {
     subnet_id = aws_subnet.public_subnet_1.id
     route_table_id = aws_route_table.public_rt.id
 }

  resource "aws_route_table_association" "public_2_assoc" {
     subnet_id = aws_subnet.public_subnet_2.id
     route_table_id = aws_route_table.public_rt.id
 }

 resource "aws_security_group" "web_sg" {
  name        = "web-sg"
  description = "Allow SSH and HTTP traffic"
  vpc_id      = aws_vpc.main.id

 ingress {
   from_port   = 22
   to_port     = 22
   protocol    = "tcp"
   cidr_blocks = ["0.0.0.0/0"]
  }

 ingress {
   from_port   = 80
   to_port     = 80
   protocol    = "tcp"
   security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

    tags = {
        Name = "web-sg"
  }
}

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP traffic from internet"
  vpc_id      = aws_vpc.main.id

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

  tags = {
    Name = "alb-sg"
  }
}

resource "aws_launch_template" "web_launch_template" {
  name = "web-launch-template"
  image_id = "ami-0f214d1b3d031dc53"
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl enable httpd
    systemctl start httpd

    aws s3 cp s3://ci-architects/index.html /var/www/html/index.html
    aws s3 cp s3://ci-architects/style.css /var/www/html/style.css
    EOF
)

    tag_specifications {
      resource_type = "instance"
        tags = {
            Name = "web-server"
      }
    }
}


 resource "aws_autoscaling_group" "web_asg" {
  name = "web-asg"
  max_size = 2
  min_size = 1
  desired_capacity = 1
  launch_template {
    id = aws_launch_template.web_launch_template.id
  }
   target_group_arns = [aws_lb_target_group.web_tg.arn]
  vpc_zone_identifier = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}

resource "aws_lb" "application_lb" {
  name               = "application-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]

  tags = {
    Name = "application-lb"
  }
}

resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
   health_check {
     healthy_threshold = 2
     unhealthy_threshold = 2
     timeout = 5
     interval = 10
     path = "/"
     protocol = "HTTP"
     matcher = "200"
   }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.application_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}