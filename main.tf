module "label" {
  source     = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.24.1"
  enabled    = var.enabled
  namespace  = var.namespace
  name       = var.name
  stage      = var.stage
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

#
# Security Group Resources
#
resource "aws_security_group" "default" {
  count  = var.enabled ? 1 : 0
  vpc_id = var.vpc_id
  name   = local.elasticache_security_group_name

  ingress {
    from_port       = var.port # Redis
    to_port         = var.port
    protocol        = "tcp"
    security_groups = var.security_groups
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = module.label.tags
}

locals {
  elasticache_subnet_group_name       = var.elasticache_subnet_group_name != "" ? var.elasticache_subnet_group_name : join("", aws_elasticache_subnet_group.default.*.name)
  elasticache_security_group_name     = var.elasticache_security_group_name != "" ? var.elasticache_security_group_name : module.label.id
  elasticache_parameter_group_name    = var.elasticache_parameter_group_name != "" ? var.elasticache_parameter_group_name : module.label.id
  cloudwatch_metric_alarm_name_prefix = var.cloudwatch_metric_alarm_name_prefix != "" ? var.cloudwatch_metric_alarm_name_prefix : module.label.id
  dns_name                            = var.dns_name != "" ? var.dns_name : var.name
}

resource "aws_elasticache_subnet_group" "default" {
  count      = var.enabled && var.elasticache_subnet_group_name == "" && length(var.subnets) > 0 ? 1 : 0
  name       = module.label.id
  subnet_ids = var.subnets
}

resource "aws_elasticache_parameter_group" "default" {
  count  = var.enabled ? 1 : 0
  name   = module.label.id
  family = var.family

  dynamic "parameter" {
    for_each = var.parameter
    content {
      name  = parameter.value.name
      value = parameter.value.value
    }
  }
}

resource "aws_elasticache_replication_group" "default" {
  count = var.enabled ? 1 : 0

  auth_token                    = var.auth_token
  replication_group_id          = var.replication_group_id == "" ? module.label.id : var.replication_group_id
  replication_group_description = module.label.id
  node_type                     = var.instance_type
  number_cache_clusters         = var.cluster_size
  port                          = var.port
  parameter_group_name          = join("", aws_elasticache_parameter_group.default.*.name)
  availability_zones            = slice(var.availability_zones, 0, var.cluster_size)
  automatic_failover_enabled    = var.automatic_failover
  subnet_group_name             = local.elasticache_subnet_group_name
  security_group_ids            = [join("", aws_security_group.default.*.id)]
  maintenance_window            = var.maintenance_window
  notification_topic_arn        = var.notification_topic_arn
  engine_version                = var.engine_version
  at_rest_encryption_enabled    = var.at_rest_encryption_enabled
  transit_encryption_enabled    = var.transit_encryption_enabled
  apply_immediately             = var.apply_immediately
  snapshot_window               = var.snapshot_window
  snapshot_retention_limit      = var.snapshot_retention_limit

  tags = module.label.tags
}

#
# CloudWatch Resources
#
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  count               = length(aws_elasticache_replication_group.default)
  alarm_name          = "${local.cloudwatch_metric_alarm_name_prefix}-cpu-utilization"
  alarm_description   = "Redis cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = "300"
  statistic           = "Average"

  threshold           = var.alarm_cpu_threshold_percent
  datapoints_to_alarm = var.alarm_datapoints_to_alarm

  dimensions = {
    CacheClusterId = tolist(aws_elasticache_replication_group.default[count.index].member_clusters)[0]
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.ok_actions
  depends_on    = [aws_elasticache_replication_group.default]
}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  count               = length(aws_elasticache_replication_group.default)
  alarm_name          = "${local.cloudwatch_metric_alarm_name_prefix}-freeable-memory"
  alarm_description   = "Redis cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = "60"
  statistic           = "Average"

  threshold           = var.alarm_memory_threshold_bytes
  datapoints_to_alarm = var.alarm_datapoints_to_alarm

  dimensions = {
    CacheClusterId = tolist(aws_elasticache_replication_group.default[count.index].member_clusters)[0]
  }

  alarm_actions = var.alarm_actions
  ok_actions    = var.ok_actions
  depends_on    = [aws_elasticache_replication_group.default]
}

module "dns" {
  source   = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.12.0"
  enabled  = var.enabled && var.zone_id != "" ? true : false
  dns_name = local.dns_name
  ttl      = 60
  zone_id  = var.zone_id
  records  = [join("", aws_elasticache_replication_group.default.*.primary_endpoint_address)]
}
