output "ec2_public_ip" {
  value = module.ghostfolio_web_srv.public_ip
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = aws_elasticache_cluster.ghostfolio_redis.cache_nodes[0].address
}