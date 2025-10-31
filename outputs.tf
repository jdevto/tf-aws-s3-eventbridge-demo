output "bucket_name" {
  value       = aws_s3_bucket.this.bucket
  description = "S3 bucket receiving PUTs to trigger the build"
}

output "event_rule_arn" {
  value       = aws_cloudwatch_event_rule.s3_put.arn
  description = "EventBridge rule ARN"
}

output "codebuild_project_name" {
  value       = aws_codebuild_project.this.name
  description = "CodeBuild project name"
}
