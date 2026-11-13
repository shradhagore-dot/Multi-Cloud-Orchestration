terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Security Group (Firewall for Kubernetes NodePort & HTTP)
resource "aws_security_group" "k8s_edge_sg" {
  name        = "k8s-edge-orchestrator-sg"
  description = "Allow Kubernetes NodePort and HTTP traffic"

  ingress {
    from_port   = 30080
    to_port     = 30080
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

# 2. Latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# 3. AWS Compute Node + Automated Kubernetes (K3s) Cluster
resource "aws_instance" "k8s_master_node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.k8s_edge_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              curl -sfL https://k3s.io | sh -
              sleep 20
              kubectl create deployment edge-web-app --image=nginxdemos/hello:latest --replicas=2
              kubectl expose deployment edge-web-app --type=NodePort --port=80 --target-port=80
              kubectl patch svc edge-web-app -p '{"spec":{"ports":[{"port":80,"nodePort":30080}]}}'
              EOF

  tags = {
    Name = "K8s-Edge-Orchestrator-Node"
  }
}

# 4. Global Edge CDN Layer (AWS CloudFront Edge Locations)
resource "aws_cloudfront_distribution" "k8s_edge_cdn" {
  enabled             = true
  comment             = "Edge Layer for Kubernetes Cluster"
  default_root_object = ""

  origin {
    domain_name = aws_instance.k8s_master_node.public_dns
    origin_id   = "k8s-origin"

    custom_origin_config {
      http_port              = 30080
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "k8s-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 5. Outputs for Your Live Demo
output "direct_kubernetes_url" {
  value = "http://${aws_instance.k8s_master_node.public_ip}:30080"
}

output "global_edge_https_url" {
  value = "https://${aws_cloudfront_distribution.k8s_edge_cdn.domain_name}"
}
