resource "random_id" "bucket_suffix" {
  byte_length = 3
}

# S3 bucket with EventBridge notifications enabled
resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_notification" "this" {
  bucket = aws_s3_bucket.this.id

  eventbridge = true
}

# CloudWatch Logs for CodeBuild
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/codebuild/${var.project_name}"
  retention_in_days = 1

  lifecycle {
    prevent_destroy = false
  }

  tags = merge(local.common_tags, {
    Name = "/codebuild/${var.project_name}"
  })
}

# IAM role for CodeBuild
resource "aws_iam_role" "codebuild_service" {
  name = "${var.project_name}-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CodeBuildAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-codebuild-role"
  })
}

resource "aws_iam_role_policy" "codebuild_service" {
  name = "${var.project_name}-codebuild-policy"
  role = aws_iam_role.codebuild_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          aws_cloudwatch_log_group.codebuild.arn,
          "${aws_cloudwatch_log_group.codebuild.arn}:*"
        ]
      },
      {
        Sid    = "S3ReadInput"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.this.arn,
          "${aws_s3_bucket.this.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_codebuild_project" "this" {
  name          = var.project_name
  description   = "Triggered by EventBridge on S3 PUT to echo event context"
  service_role  = aws_iam_role.codebuild_service.arn
  build_timeout = 10

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = false
    image_pull_credentials_type = "CODEBUILD"
    environment_variable {
      name  = "EVENT_BUCKET"
      value = ""
      type  = "PLAINTEXT"
    }
    environment_variable {
      name  = "EVENT_KEY"
      value = ""
      type  = "PLAINTEXT"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild.name
      stream_name = var.project_name
      status      = "ENABLED"
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = "version: 0.2\nphases:\n  install:\n    commands:\n      - echo 'Skipping install - no dependencies needed'\n  build:\n    commands:\n      - echo 'Build started'\n      - echo \"Bucket is $${EVENT_BUCKET}\"\n      - echo \"Key is $${EVENT_KEY}\"\n"
  }

  tags = merge(local.common_tags, {
    Name = var.project_name
  })
}

# Role assumed by EventBridge to call codebuild:StartBuild on this project
resource "aws_iam_role" "events_invoke_codebuild" {
  name = "${var.project_name}-events-invoke"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventsAssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-events-invoke"
  })
}

resource "aws_iam_role_policy" "events_invoke_codebuild" {
  name = "${var.project_name}-events-invoke-inline"
  role = aws_iam_role.events_invoke_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StartSpecificBuild"
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.this.arn
      }
    ]
  })
}

# EventBridge rule for S3 Object Created:Put on our bucket
resource "aws_cloudwatch_event_rule" "s3_put" {
  name        = "${var.project_name}-s3-put"
  description = "Log and react to S3 object creates for this bucket"
  event_pattern = jsonencode({
    "source" : ["aws.s3"],
    "detail-type" : ["Object Created", "Object Created:Put"],
    "detail" : {
      "bucket" : { "name" : [aws_s3_bucket.this.bucket] }
    }
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-put"
  })
}

# Lambda logger to capture full event reliably
data "archive_file" "lambda_logger_zip" {
  type        = "zip"
  output_path = "lambda_logger.zip"

  source {
    content  = <<-PY
      import json
      import os
      import logging

      logger = logging.getLogger()
      logger.setLevel(logging.INFO)

      def handler(event, context):
          logger.info("EVENTBRIDGE EVENT: %s", json.dumps(event))
          return {"ok": True}
    PY
    filename = "lambda_function.py"
  }
}

resource "aws_iam_role" "lambda_logger" {
  name = "${var.project_name}-lambda-logger-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "LambdaAssumeRole",
        Effect    = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-lambda-logger-role" })
}

resource "aws_iam_role_policy" "lambda_logger" {
  name = "${var.project_name}-lambda-logger-inline"
  role = aws_iam_role.lambda_logger.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "LogsWrite",
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# CloudWatch Logs group for Lambda logger
resource "aws_cloudwatch_log_group" "lambda_logger" {
  name              = "/aws/lambda/${var.project_name}-logger"
  retention_in_days = 1

  lifecycle {
    prevent_destroy = false
  }

  tags = merge(local.common_tags, {
    Name = "/aws/lambda/${var.project_name}-logger"
  })
}

resource "aws_lambda_function" "logger" {
  function_name    = "${var.project_name}-logger"
  role             = aws_iam_role.lambda_logger.arn
  handler          = "lambda_function.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_logger_zip.output_path
  source_code_hash = data.archive_file.lambda_logger_zip.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.lambda_logger]

  tags = merge(local.common_tags, { Name = "${var.project_name}-logger" })
}

resource "aws_lambda_permission" "allow_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.logger.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_put.arn
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.s3_put.name
  arn       = aws_lambda_function.logger.arn
  target_id = "lambda-logger"
}

resource "aws_cloudwatch_event_target" "codebuild_target" {
  rule     = aws_cloudwatch_event_rule.s3_put.name
  arn      = aws_codebuild_project.this.arn
  role_arn = aws_iam_role.events_invoke_codebuild.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<-JSON
      {
        "environmentVariablesOverride": [
          {"name": "EVENT_BUCKET", "type": "PLAINTEXT", "value": "<bucket>"},
          {"name": "EVENT_KEY", "type": "PLAINTEXT", "value": "<key>"}
        ]
      }
    JSON
  }

  dead_letter_config {
    arn = aws_sqs_queue.codebuild_dlq.arn
  }
}

# Dead Letter Queue for CodeBuild target failures
resource "aws_sqs_queue" "codebuild_dlq" {
  name                      = "${var.project_name}-codebuild-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-codebuild-dlq"
  })
}

resource "aws_sqs_queue_policy" "codebuild_dlq" {
  queue_url = aws_sqs_queue.codebuild_dlq.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "AllowEventBridgeToSendToDLQ",
        Effect    = "Allow",
        Principal = { Service = "events.amazonaws.com" },
        Action    = "sqs:SendMessage",
        Resource  = aws_sqs_queue.codebuild_dlq.arn,
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.s3_put.arn
          }
        }
      }
    ]
  })
}
