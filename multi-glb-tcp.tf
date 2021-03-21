provider "google" {
  #   version = "3.5.0"
  # Update credentials to the correct location, alternatively set   GOOGLE_APPLICATION_CREDENTIALS=/path/to/.ssh/bq-key.json in your shell session and   remove the credentials attribute.
  #   credentials = file("cliu201-sa.json")
  project = "cliu201"
  region  = "us-central1"
  zone    = "us-central1-c"

}

// ali ip list
locals {
  ali_ips = {
    "game1" = "1.1.1.1"
    "game2" = "2.2.2.2"
  }

  named_port = {
    "game1" = 9001
    "game2" = 9002
  }

}


###########################         01-create instance template         ########################### 
resource "google_compute_instance_template" "nginx" {
  name        = "nginx-to-ali-template"
  description = "This template is used to create reversed proxy MIG."

  tags = ["nginx"]

  instance_description = "description assigned to instances"
  machine_type         = "e2-medium"
  can_ip_forward       = false

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  // Create a new boot disk from an image
  disk {
    source_image = "debian-cloud/debian-9"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"
  }


  service_account {
    scopes = ["cloud-platform"]
  }


}

data "google_compute_image" "my_image" {
  family  = "debian-9"
  project = "debian-cloud"
}


########################### 02-create managed instance group with ha and autoscaling         ########################### 

resource "google_compute_health_check" "autohealing" {
  name                = "autohealing-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 50 seconds

  http_health_check {
    request_path = "/"
    port         = "8080"
  }
}

resource "google_compute_region_instance_group_manager" "nginx" {
  name = "nginx-igm"

  base_instance_name        = "nginx-ali"
  region                    = "us-central1"
  distribution_policy_zones = ["us-central1-a", "us-central1-f"]

  version {
    instance_template = google_compute_instance_template.nginx.id
  }

  target_size = 2

  dynamic "named_port" {
    for_each = local.named_port
    content {
      name = named_port.key
      port = named_port.value
    }
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 300
  }

  depends_on = [
    google_compute_instance_template.nginx
  ]
}

########################### 03-create multiple global ips and glb tcp proxy ########################### 
resource "google_compute_global_address" "global_ips" {
  for_each = local.ali_ips

  name = each.key
  #   name = "test"
}

resource "google_compute_backend_service" "glb-be" {
  for_each = local.named_port
  
  name        = "glb-${each.key}"
  protocol    = "TCP"
  timeout_sec = 10
#   port_name = google_compute_region_instance_group_manager.nginx.named_port["game2"].name
  port_name = each.key
  health_checks = [google_compute_health_check.glb-hc.id]

# https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_instance_group_manager#attributes-reference
# refer to this doc to use this attribute to get the full URL
  backend {
    group = google_compute_region_instance_group_manager.nginx.instance_group
  }
}

# https://www.terraform.io/docs/configuration/expressions.html#references-to-resource-attributes
resource "google_compute_target_tcp_proxy" "glb-tcp-proxy" {
  for_each = local.named_port

  name            = "glb-tcp-proxy-${each.key}"
  backend_service = google_compute_backend_service.glb-be[each.key].id
}

resource "google_compute_global_forwarding_rule" "global-rule" {
  for_each = local.named_port

  name       = "global-rule-${each.key}"
  target     = google_compute_target_tcp_proxy.glb-tcp-proxy[each.key].id
  ip_address = google_compute_global_address.global_ips[each.key].address
  ip_protocol    = "TCP"
  port_range = "1883"
}


# Load Balancer health check should be more aggressive
resource "google_compute_health_check" "glb-hc" {
  name               = "glb-hc"
  timeout_sec        = 1
  check_interval_sec = 1
  healthy_threshold   = 2
  unhealthy_threshold = 10 # 10 seconds

  tcp_health_check {
    port = "8080"
  }
}
