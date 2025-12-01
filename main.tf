# ==============================
# 1. Terraform 版本与 Provider 约束
# ==============================
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 1.200.0"
    }
  }
}

# ==============================
# 2. 阿里云 Provider 配置
# ==============================
provider "alicloud" {
  region = "cn-beijing"  # 按需修改地域
  
  # PowerShell: $env:ALICLOUD_ACCESS_KEY="你的AK"; $env:ALICLOUD_SECRET_KEY="你的SK"
}

# ==============================
# 3. 自定义变量
# ==============================
variable "ecs_login_password" {
  type        = string
  default     = "Admin@123456"  # 符合阿里云密码规范
  description = "ECS 登录密码"
}

variable "name_prefix" {
  type        = string
  default     = "test"
}

variable "instance_type" {
  type        = string
  default     = "ecs.e-c1m1.large"
}

variable "target_zone_id" {
  type        = list(string)
  default     = ["cn-beijing-a","cn-beijing-b"]  # 按需修改可用区
}

# ==============================
# 4. 基础资源：VPC
# ==============================
resource "alicloud_vpc" "main" {
  vpc_name   = "${var.name_prefix}-vpc"
  cidr_block = "172.16.0.0/12"
  tags = {
    Name = "${var.name_prefix}-vpc"
    Env  = "test"
  }
}

# ==============================
# 5. 双可用区子网（核心修改：循环创建两个子网）
# ==============================
resource "alicloud_vswitch" "main" {
  # 循环次数 = 可用区列表长度（2次，生成两个子网）
  count = length(var.target_zone_ids)

  # 1. 关联VPC（所有子网属于同一个VPC）
  vpc_id = alicloud_vpc.main.id

  # 2. 子网网段：按可用区序号偏移（避免冲突）
  # 示例：第1个可用区（index=0）→ 172.16.0.0/21，第2个（index=1）→ 172.16.8.0/21
  cidr_block = cidrsubnet(var.vpc_cidr, 9, count.index)  # 子网掩码从/12扩展9位→/21，偏移量=count.index

  # 3. 可用区：循环取可用区列表的第N个值（index=0→第一个可用区，index=1→第二个）
  zone_id = var.target_zone_ids[count.index]

  # 4. 子网名称：拼接可用区标识（如 "ecs-intranet-password-vsw-cn-beijing-a"）
  vswitch_name = "${var.name_prefix}-vsw-${var.target_zone_ids[count.index]}"

  # 5. 标签：添加可用区标签，便于管理
  tags = {
    Name     = "${var.name_prefix}-vsw-${var.target_zone_ids[count.index]}"
    Env      = "test"
    ZoneId   = var.target_zone_ids[count.index]  # 标签显示可用区
    SubnetIndex = count.index  # 标签显示子网序号（0/1）
  }
}

# ==============================
# 6. 安全组（拆分多端口为独立规则，修复端口格式错误）
# ==============================
resource "alicloud_security_group" "main" {
  security_group_name = "${var.name_prefix}-sg"
  vpc_id              = alicloud_vpc.main.id
  tags = {
    Name = "${var.name_prefix}-sg"
    Env  = "test"
  }
}

# 规则1：放行内网 SSH（22端口）
resource "alicloud_security_group_rule" "allow_intranet_ssh" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "22/22"  # 单个端口格式：端口/端口
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则2：放行内网 HTTP（80端口）- 拆分独立规则
resource "alicloud_security_group_rule" "allow_intranet_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"  # 单独写80端口，不与443合并
  priority          = 2
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则3：放行内网 HTTPS（443端口）- 拆分独立规则
resource "alicloud_security_group_rule" "allow_intranet_https" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "443/443"  # 单独写443端口
  priority          = 3
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = alicloud_vpc.main.cidr_block
}

# 规则4：放行内网出方向流量
resource "alicloud_security_group_rule" "allow_intranet_egress" {
  type              = "egress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"  # 所有端口
  priority          = 1
  security_group_id = alicloud_security_group.main.id
  cidr_ip           = "0.0.0.0/0"
}
variable "image_id" {
  default = "ubuntu_22_04_x64_20G_alibase_20251103.vhd"
}


# ==============================
# 8. 多可用区 ECS 实例（每个子网 1 台）
# ==============================
resource "alicloud_instance" "main" {
  # 核心：ECS 数量 = 子网数量（count 与子网保持一致）
  count = length(alicloud_vswitch.main)

  # 1. ECS 名称：拼接序号+可用区，避免冲突（如 "ecs-intranet-password-instance-0-cn-beijing-a"）
  instance_name = "${var.name_prefix}-instance-${count.index}-${var.target_zone_ids[count.index]}"

  # 2. 可用区：与对应子网的可用区一致（一一绑定）
  availability_zone = var.target_zone_ids[count.index]

  # 3. 实例规格（复用变量）
  instance_type = var.instance_type

  # 4. 系统盘配置（不变）
  system_disk_category = "cloud_essd_entry"
  system_disk_size     = 40

  # 5. 网络配置：绑定对应序号的子网（1 台 ECS 对应 1 个子网）
  vswitch_id                 = alicloud_vswitch.main[count.index].id  # 关键：引用同序号子网 ID
  security_groups            = [alicloud_security_group.main.id]  # 所有 ECS 共用一个安全组
  internet_max_bandwidth_out = 0  # 无公网 IP
  internet_charge_type       = "PayByTraffic"

  # 6. 镜像配置（复用变量，推荐用数据源查询）
  image_id = var.image_id

  # 7. 密码登录（不变）
  password         = var.ecs_login_password
  password_inherit = false

  # 8. 计费与保护（不变）
  instance_charge_type = "PostPaid"  # 按量付费
  deletion_protection  = false      # 防止误删

  # 9. 标签：添加序号和可用区，便于管理
  tags = {
    Name     = "${var.name_prefix}-instance-${count.index}-${var.target_zone_ids[count.index]}"
    Env      = "test"
    PublicIP = "Disabled"
    ZoneId   = var.target_zone_ids[count.index]  # 标签显示可用区
    SubnetIndex = count.index  # 标签显示对应子网序号
  }
}

# ==============================
# 9. 输出所有 ECS 信息（部署后查看）
# ==============================
output "ecs_instances_info" {
  value = [
    for idx, instance in alicloud_instance.main : {
      ecs_id       = instance.id
      name         = instance.instance_name
      zone_id      = instance.availability_zone
      vswitch_id   = instance.vswitch_id
      private_ip   = instance.private_ip
      login_user   = "root"  # CentOS 默认用户名
      login_password = var.ecs_login_password
      login_command = "ssh root@${instance.private_ip}"
    }
  ]
  description = "所有 ECS 实例的登录信息和网络配置"
}

# ==============================
# 9. 输出信息
# ==============================
output "ecs_id" {
  value       = alicloud_instance.main.id
  description = "ECS 实例 ID"
}

output "ecs_private_ip" {
  value       = alicloud_instance.main.private_ip
  description = "ECS 内网 IP（仅 VPC 内可访问）"
}

output "login_info" {
  value = <<EOT
  登录方式：SSH 密码登录（仅 VPC 内网）
  登录地址：${alicloud_instance.main.private_ip}
  用户名：root（CentOS 默认）
  登录密码：${var.ecs_login_password}
  登录命令：ssh root@${alicloud_instance.main.private_ip}
  注意：需在 VPC 内其他机器（如堡垒机）执行登录
  EOT
  description = "ECS 登录信息（妥善保管密码）"
}

output "used_image_id" {
  value       = alicloud_instance.main.image_id
  description = "实际使用的镜像 ID（100% 有效）"
}
