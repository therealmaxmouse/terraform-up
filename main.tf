provider "aws" {
	region = "us-east-2"
}

data "aws_vpc" "default" {
	default = true
}

data "aws_subnet_ids" "default" {
	vpc_id = data.aws_vpc.default.id
}

variable "server_port" {
        description = "The port the server will use for HTTP requests"
        type = number
        default = 8080
}

#output "public_ip" {
#	value = aws_instance.mm-single-web.public_ip
#	description = "The public IP address of the web server"
#}

output "alb_dns_name" {
	value = aws_lb.mm-web-cluster.dns_name
	description = "The domain name of the load balancer"
}

# examples using a single subnet.  not ideal for prod.
resource "aws_lb" "mm-web-cluster" {
	name = "terraform-asg-example"
	load_balancer_type = "application"
	subnets = data.aws_subnet_ids.default.ids
	security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
	load_balancer_arn = aws_lb.mm-web-cluster.arn
	port = 80
	protocol = "HTTP"
	# By default, return a simple 404 page
	default_action {
		type = "fixed-response"
		
		fixed_response {
			content_type = "text/plain"
			message_body = "404: page not foooond"
			status_code = 404
		}
	}
}

resource "aws_lb_listener_rule" "asg" {
	listener_arn = aws_lb_listener.http.arn
	priority = 100

	condition {
		path_pattern {
			values = ["*"]
		}
	}

	action {
		type = "forward"
		target_group_arn = aws_lb_target_group.asg.arn
	}
}

resource "aws_lb_target_group" "asg" {
	name = "terraform-asg-example"
	port = var.server_port
	protocol = "HTTP"
	vpc_id = data.aws_vpc.default.id

	health_check {
		path = "/"
		protocol = "HTTP"
		matcher = "200"
		interval = 15
		timeout = 3
		healthy_threshold = 2
		unhealthy_threshold = 2
	}
}

resource "aws_security_group" "alb" {
	name = "terraform-example-alb"

	# Allow inbound HTTP requests
	ingress {
		from_port = 80
		to_port = 80
		protocol = "tcp"
		cidr_blocks = ["0.0.0.0/0"]
	}
	
	# Allow all outbound requests from load balancers 
	egress {
		from_port = 0
		to_port = 0
		protocol = "-1"
		cidr_blocks = ["0.0.0.0/0"]
	}

}

resource "aws_security_group" "instance" {
        name = "terraform-example-instance"

        ingress {
                from_port = var.server_port
                to_port = var.server_port
                protocol = "tcp"
                cidr_blocks = ["0.0.0.0/0"]
        }

}

resource "aws_launch_configuration" "mm-web-cluster" {
	image_id = "ami-0c55b159cbfafe1f0"
	instance_type = "t2.micro"
	security_groups = [aws_security_group.instance.id]

	user_data = <<-EOF
                    #!/bin/bash
                    echo "yeep" > index.html
                    nohup busybox httpd -f -p ${var.server_port} &
                    EOF

	#Required when using a launch configuration with an auto scaling group. 
	# See https://terraform.io/docs/providers/aws/r/launch_configuration.html
	lifecycle {
		create_before_destroy = true
	}
}

resource "aws_autoscaling_group" "mm-web-cluster" {
	launch_configuration = aws_launch_configuration.mm-web-cluster.name
	vpc_zone_identifier = data.aws_subnet_ids.default.ids

	target_group_arns = [aws_lb_target_group.asg.arn]
	health_check_type = "ELB"

	min_size = 2
	max_size = 10

	tag {
		key = "Name"
		value = "terraform-asg-example"
		propagate_at_launch = true
	}
}

