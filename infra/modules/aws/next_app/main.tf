# A Next.js app built with OpenNext, served from the client's account:
#
#   viewer ─► CloudFront ─┬─ /_next/static/* ─► S3 assets bucket (OAC, private)
#                         └─ everything else  ─► API Gateway (HTTP API) ─► Lambda
#
# Terraform owns the infrastructure only. The app's code and its settings (the
# Lambda zip and environment, the files in the assets bucket) are shipped by a
# deploy workflow, so a release is a workflow run, not an apply, and secrets
# never land in Terraform state. Until the first deploy the Lambda answers 503.
#
# Why API Gateway and not a Lambda function URL: CloudFront's origin access
# control signs requests to a function URL, but then every POST/PUT must carry a
# hash of its body computed by the browser (Lambda rejects unsigned payloads), and
# an open (NONE) function URL needs a public lambda:InvokeFunction grant that this
# provider version can't limit to URL calls. An HTTP API is invoked with a grant
# scoped to that one API.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  server_name = "${var.name_prefix}-server"
}

# --- Static assets (/_next/static/*) ----------------------------------------

resource "aws_s3_bucket" "assets" {
  bucket        = "${var.name_prefix}-assets-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.name_prefix}-assets-oac"
  description                       = "OAC for ${var.domain} assets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "assets_cloudfront" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.assets.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.app.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket     = aws_s3_bucket.assets.id
  policy     = data.aws_iam_policy_document.assets_cloudfront.json
  depends_on = [aws_s3_bucket_public_access_block.assets]
}

# --- Server function ---------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Named <name_prefix>-server so it falls under the Terraform role's
# <client>-* IAM scope (and its iam:PassRole grant).
resource "aws_iam_role" "server" {
  name               = local.server_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "server" {
  name              = "/aws/lambda/${local.server_name}"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "server" {
  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.server.arn}:*"]
  }
}

resource "aws_iam_role_policy" "server" {
  name   = local.server_name
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

# Placeholder code so the function can exist before the first deploy.
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/.build/placeholder.zip"

  source {
    filename = "index.mjs"
    content  = <<-EOT
      export const handler = async () => ({
        statusCode: 503,
        headers: { "content-type": "text/plain" },
        body: "Not deployed yet.",
      });
    EOT
  }
}

resource "aws_lambda_function" "server" {
  function_name    = local.server_name
  role             = aws_iam_role.server.arn
  runtime          = var.lambda_runtime
  handler          = "index.handler"
  architectures    = ["x86_64"]
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_seconds
  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  # The deploy workflow owns the code and the environment (it holds the secrets).
  lifecycle {
    ignore_changes = [filename, source_code_hash, environment]
  }

  depends_on = [aws_cloudwatch_log_group.server, aws_iam_role_policy.server]
}

# --- API Gateway (HTTP API) --------------------------------------------------

resource "aws_apigatewayv2_api" "app" {
  name          = var.name_prefix
  protocol_type = "HTTP"
  description   = "${var.domain} (origin for CloudFront)"
}

resource "aws_apigatewayv2_integration" "server" {
  api_id                 = aws_apigatewayv2_api.app.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.server.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.app.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.server.id}"
}

# Throttling caps what a flood of requests can cost; far above a small team's use.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.app.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.throttle_burst
    throttling_rate_limit  = var.throttle_rate
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.server.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.app.execution_arn}/*/*"
}

# --- CloudFront ----------------------------------------------------------------

# API Gateway needs its own Host header, so CloudFront doesn't forward the
# viewer's; this hands the real host to the app (OpenNext reads
# x-forwarded-host) so redirects and invite links use the client's domain.
resource "aws_cloudfront_function" "forward_host" {
  name    = "${var.name_prefix}-forward-host"
  runtime = "cloudfront-js-2.0"
  comment = "Copy Host into x-forwarded-host for the app"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      request.headers['x-forwarded-host'] = { value: request.headers.host.value };
      return request;
    }
  EOT
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  api_origin_id    = "api-${aws_apigatewayv2_api.app.id}"
  assets_origin_id = "s3-${aws_s3_bucket.assets.id}"
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = var.domain
  aliases         = [var.domain]
  price_class     = var.price_class

  origin {
    domain_name = replace(aws_apigatewayv2_api.app.api_endpoint, "https://", "")
    origin_id   = local.api_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name              = aws_s3_bucket.assets.bucket_regional_domain_name
    origin_id                = local.assets_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  # Pages and API routes: never cached, every viewer header except Host passed on.
  default_cache_behavior {
    target_origin_id         = local.api_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.forward_host.arn
    }
  }

  # Build-hashed JS/CSS: cached hard, straight from S3.
  ordered_cache_behavior {
    path_pattern           = "/_next/static/*"
    target_origin_id       = local.assets_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = module.certificate.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- TLS + DNS -----------------------------------------------------------------

module "certificate" {
  source = "../acm_certificate"
  providers = {
    aws = aws.us_east_1
  }

  domain_name    = var.domain
  hosted_zone_id = var.hosted_zone_id
}

resource "aws_route53_record" "a" {
  zone_id = var.hosted_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "aaaa" {
  zone_id = var.hosted_zone_id
  name    = var.domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}
