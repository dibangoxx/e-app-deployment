###############################################################################
# Root Outputs
###############################################################################

output "vpc_id" { value = module.network.vpc_id }
output "alb_dns_name" { value = module.network.alb_dns_name }
output "cloudfront_domain" { value = module.frontend.cloudfront_domain }
output "cognito_user_pool_id" { value = module.identity.user_pool_id }
output "aurora_cluster_endpoint" { value = module.data.aurora_cluster_endpoint }
output "redis_endpoint" { value = module.data.redis_primary_endpoint }
output "opensearch_endpoint" { value = module.data.opensearch_endpoint }
output "documents_bucket" { value = module.data.documents_bucket_name }
output "event_bus_name" { value = module.api_eventing.event_bus_name }
output "ecr_api_url" { value = module.devsecops.ecr_api_url }
output "ecr_web_url" { value = module.devsecops.ecr_web_url }
output "ecs_cluster_name" { value = module.runtime.ecs_cluster_name }
output "checkout_sfn_arn" { value = module.api_eventing.checkout_sfn_arn }
output "data_lake_bucket" { value = module.analytics.data_lake_bucket }
output "athena_workgroup" { value = module.analytics.athena_workgroup_name }
