# ==============================
# 新增：ALB 相关变量（按需调整）
# ==============================
variable "alb_name" {
  type        = string
  default     = "${var.name_prefix}-alb"
  description = "ALB 实例名称"
}

variable "alb_server_group_name" {
  type        = string
  default     = "${var.name_prefix}-alb-server-group"
  description = "ALB 后端服务器组名称"
}

variable "alb_listen_port" {
  type        = number
  default     = 80
  description = "ALB 监听端口（HTTP 默认 80，HTTPS 改为 443）"
}

variable "alb_listen_protocol" {
  type        = string
  default     = "HTTP"
  description = "ALB 监听协议（HTTP/HTTPS）"
}

# ==============================
# 1. ALB 实例（双可用区部署，与 ECS 同可用区）
# ==============================
resource "alicloud_alb_load_balancer" "main" {
  # 实例基本信息
  load_balancer_name = var.alb_name
  vpc_id             = alicloud_vpc.main.id  # 关联现有 VPC
  address_type       = "internet"  # 公网地址（允许公网访问）
  address_allocated_mode = "Dynamic"  # 动态 IP（按需改为 Fixed 固定 IP）
  load_balancer_edition = "Standard"  # 标准版（满足高可用+负载均衡需求）

  # 计费配置（按量付费，销毁即停费）
  load_balancer_billing_config {
    pay_type = "PayAsYouGo"
  }

  # 核心：ALB 双可用区部署（循环遍历两个可用区，与子网一一对应）
  dynamic "zone_mappings" {
    for_each = { for idx, subnet in alicloud_vswitch.main : idx => subnet }  # 遍历两个子网
    content {
      zone_id    = zone_mappings.value.zone_id  # 复用子网的可用区（双可用区）
      vswitch_id = zone_mappings.value.id        # 复用子网 ID（每个可用区对应一个子网）
    }
  }

  # 安全组：复用现有安全组（已放行 80/443 端口，无需额外配置）
  security_group_ids = [alicloud_security_group.main.id]

  # 保护配置（防止误删）
  deletion_protection_enabled = true
  modification_protection_config {
    status = "ConsoleProtection"  # 仅控制台保护，允许 Terraform 操作
    reason = "High-availability ALB, prevent accidental modification"
  }

  tags = {
    Name   = var.alb_name
    Env    = "test"
    Source = "Terraform"
    HA     = "Multi-AZ"  # 标记为多可用区高可用架构
  }
}

# ==============================
# 2. ALB 后端服务器组（关联两台 ECS，实现负载均衡）
# ==============================
resource "alicloud_alb_server_group" "main" {
  server_group_name = var.alb_server_group_name
  vpc_id            = alicloud_vpc.main.id  # 关联现有 VPC
  protocol          = "HTTP"  # 后端 ECS 通信协议（与 ECS 服务协议一致）

  # 健康检查配置（核心！确保只转发流量到正常 ECS）
  health_check_config {
    health_check_enabled      = true
    health_check_protocol     = "HTTP"
    health_check_connect_port = 80  # ECS 服务端口（需与 ECS 部署的服务端口一致）
    health_check_path         = "/health"  # 健康检查接口（ECS 需部署，返回 200）
    health_check_method       = "GET"
    health_check_codes        = ["200"]  # 返回 200 视为健康
    health_check_interval     = 5        # 检查间隔 5 秒
    health_check_timeout      = 3        # 超时 3 秒
    healthy_threshold         = 3        # 连续 3 次健康则标记正常
    unhealthy_threshold       = 3        # 连续 3 次失败则剔除（故障自愈）
  }

  # 会话保持（可选，适合登录态保持场景，如电商登录后会话）
  sticky_session_config {
    sticky_session_enabled = true
    sticky_session_type    = "Insert"  # ALB 自动插入 Cookie
    cookie                 = "ALB-STICKY-SESSION"
    cookie_ttl             = 3600      # Cookie 有效期 1 小时（同一用户请求转发到同一 ECS）
  }

  # 核心：自动关联两台 ECS（循环遍历所有 ECS，无需手动填写）
  dynamic "servers" {
    for_each = { for idx, ecs in alicloud_instance.main : idx => ecs }  # 遍历两台 ECS
    content {
      server_id   = servers.value.id          # ECS 实例 ID
      server_ip   = servers.value.private_ip  # ECS 内网 IP（ALB 内网访问）
      port        = 80                        # ECS 服务端口（与健康检查端口一致）
      weight      = 100                       # 流量权重（两台均为 100，流量均分）
      description = servers.value.instance_name  # ECS 名称（便于运维识别）
      server_type = "Ecs"                     # 服务器类型为 ECS
    }
  }

  tags = {
    Name   = var.alb_server_group_name
    Env    = "test"
    Source = "Terraform"
    ECS_Count = length(alicloud_instance.main)  # 标记关联的 ECS 数量
  }
}

# ==============================
# 3. ALB 监听规则（接收公网流量，转发到后端双 ECS）
# ==============================
resource "alicloud_alb_listener" "main" {
  listener_name    = "${var.alb_name}-listener"
  load_balancer_id = alicloud_alb_load_balancer.main.id  # 关联 ALB 实例
  port             = var.alb_listen_port  # 监听端口（80/443）
  protocol         = var.alb_listen_protocol  # 监听协议（HTTP/HTTPS）

  # 转发规则：所有公网流量转发到后端双 ECS 服务器组
  default_actions {
    type            = "ForwardGroup"
    server_group_id = alicloud_alb_server_group.main.id  # 关联后端服务器组
    forward_group_config {
      target_group_tuple {
        server_group_id = alicloud_alb_server_group.main.id
        weight          = 100
      }
    }
  }

  # 监听属性配置（优化连接稳定性）
  listener_attributes {
    idle_timeout = 60  # 连接超时 60 秒（避免无效连接占用资源）
  }

  tags = {
    Name = "${var.alb_name}-listener"
    Env  = "test"
  }
}

# ==============================
# 新增：ALB 高可用输出信息（部署后查看，用于测试访问）
# ==============================
output "alb_ha_info" {
  value = {
    alb_public_ip        = alicloud_alb_load_balancer.main.address  # ALB 公网 IP（唯一入口）
    alb_az_config        = [for zone in alicloud_alb_load_balancer.main.zone_mappings : zone.zone_id]  # ALB 部署的可用区
    alb_listen_port      = alicloud_alb_listener.main.port
    public_access_url    = "${var.alb_listen_protocol}://${alicloud_alb_load_balancer.main.address}:${alicloud_alb_listener.main.port}"  # 公网访问地址
    backend_server_group = alicloud_alb_server_group.main.id
    bound_ecs_info       = [for ecs in alicloud_instance.main : {
      ecs_id       = ecs.id
      ecs_private_ip = ecs.private_ip
      ecs_zone     = ecs.availability_zone
      weight       = 100
    }]
    ha_desc              = "ALB 双可用区部署 + 双 ECS 负载均衡，单可用区/ECS 故障不影响服务"
  }
  description = "ALB 高可用配置信息和访问地址"
}
