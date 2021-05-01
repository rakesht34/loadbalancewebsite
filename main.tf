provider "aws" {
access_key = "${var.aws_access_key}"
secret_key = "${var.aws_secret_key}"
region = "${var.region}"
}

# Create an VPC with private and public subnets across different az's
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name = "hello-world-vpc"
  cidr = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  enable_nat_gateway = true
  tags = {
    Terraform = "true"
    Project = "hello-world"
  }
}

# Create an autoscaling group
resource "aws_autoscaling_group" "hello-world-asg" {
  name = "hello-world-asg"
  launch_configuration = "${aws_launch_configuration.hello-world-lc.id}"
  vpc_zone_identifier       = module.vpc.private_subnets
  min_size = 2
  max_size =4
  load_balancers = ["${aws_elb.hello-world-elb.name}"]
  health_check_type = "ELB"
  tag {
    key = "Name"
    value = "hello-world-ASG"
    propagate_at_launch = true
  }
}

# Create autoscaling policy -> target at a 70% average CPU load
resource "aws_autoscaling_policy" "hello-world-asg-policy-1" {
  name                   = "hello-world-asg-policy"
  policy_type            = "TargetTrackingScaling"
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = "${aws_autoscaling_group.hello-world-asg.name}"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}
# Create EC2 Key Pair
resource "tls_private_key" "hello" {
  algorithm = "RSA"
}

module "key_pair" {
  source = "terraform-aws-modules/key-pair/aws"
  key_name   = "hello-world"
  public_key = tls_private_key.hello.public_key_openssh
}

# Create launch configuration
resource "aws_launch_configuration" "hello-world-lc" {
  name = "hello-world-lc"
  image_id = "ami-0cf7303350c82d042"
  instance_type = "t2.small"
  key_name = "${module.key_pair.key_pair_key_name}"
  security_groups = ["${aws_security_group.hello-world-lc-sg.id}"]
  user_data = <<-EOF
		      #!/bin/bash
              sudo apt-get update
		      sudo apt-get install -y apache2
		      sudo systemctl start apache2
		      sudo systemctl enable apache2
              EC2_AVAIL_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
		      echo "<h1>Hello World! from Rakesh at $(hostname -f) in AZ $EC2_AVAIL_ZONE </h1>" | sudo tee /var/www/html/index.html
	          EOF

  lifecycle {
    create_before_destroy = true
  }
}

# Create the ELB
resource "aws_elb" "hello-world-elb" {
  name = "hello-world-elb"
  security_groups = ["${aws_security_group.hello-world-elb-sg.id}"]
#   availability_zones = module.vpc.azs
  subnets = module.vpc.public_subnets

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    interval = 30
    #target = "TCP:${var.server_port}"
    target = "HTTP:80/index.html"
  }

  # This adds a listener for incoming HTTP requests.
  listener {
    lb_port = 80
    lb_protocol = "http"
    instance_port = "80"
    instance_protocol = "http"
  }
}
#elb dns to reach web site
output "elb_dns_name" {
  value       = aws_elb.hello-world-elb.dns_name
  description = "The domain name of the load balancer"
}

# Create security group that's applied the launch configuration
resource "aws_security_group" "hello-world-lc-sg" {
  name = "hello-world-lc-sg"
  vpc_id = "${module.vpc.vpc_id}"

  # Inbound HTTP from vpc cidr
  ingress {
    description = "port 80 open to elb sg"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    # cidr_blocks = [module.vpc.vpc_cidr_block]
    security_groups = ["${aws_security_group.hello-world-elb-sg.id}"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Create security group that's applied to the ELB
resource "aws_security_group" "hello-world-elb-sg" {
  name = "hello-world-elb-sg"
  vpc_id = "${module.vpc.vpc_id}"

  # Allow all outbound
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound HTTP from anywhere
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

