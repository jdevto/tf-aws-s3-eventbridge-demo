# S3 EventBridge CodeBuild Demo

Terraform demo that sets up an automated pipeline where S3 object PUT events trigger an EventBridge rule, which starts a CodeBuild project.

## Architecture

- S3 bucket with EventBridge notifications enabled
- EventBridge rule matching S3 "Object Created" events
- CodeBuild project that echoes the bucket and key from the event
- Lambda function for event logging and debugging
- Dead Letter Queue (DLQ) for failed CodeBuild invocations

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- AWS provider >= 6.0
- Random provider >= 3.0
- Archive provider >= 2.4

## Usage

### Deploy

```bash
terraform init
terraform apply
```

### Test

Upload a file to the S3 bucket:

```bash
aws s3 cp test.txt s3://$(terraform output -raw bucket_name)/test/test.txt
```

Check CodeBuild builds:

```bash
aws codebuild list-builds-for-project --project-name $(terraform output -raw codebuild_project_name)
```

View CodeBuild logs:

```bash
aws logs tail /codebuild/$(terraform output -raw codebuild_project_name) --follow
```

### Cleanup

```bash
terraform destroy
```

## Variables

- `project_name` (default: `"s3-eb-codebuild-demo"`) - Base name for all resources
