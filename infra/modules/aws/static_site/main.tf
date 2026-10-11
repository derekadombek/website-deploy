# A private S3 bucket fronted by CloudFront. The bucket is never public — only
# this distribution can read it, via an Origin Access Control.

# --- S3 (private origin) ----------------------------------------------------

# Bucket name is decoupled from the public domain on purpose: S3 names are
# globally unique and a deleted name takes time to free, so reusing the domain
# as the bucket name makes delete/recreate (and region moves) stall. CloudFront
# uses the bucket's regional endpoint as origin, so the name is internal-only.
#
# The account ID suffix guarantees global uniqueness — a bare "<project>-site"
# collides with other accounts' buckets in the shared S3 namespace.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "site" {
  bucket        = "${var.name_prefix}-site-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- CloudFront (CDN + TLS) -------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name_prefix}-oac"
  description                       = "OAC for ${var.site_domain}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

locals {
  # A custom domain (alias + ACM cert) is attached only when a cert ARN is
  # supplied. Without one, CloudFront serves its default *.cloudfront.net domain
  # with the default certificate — the "ship S3 only" recipe (manage_dns=false).
  custom_domain = var.acm_certificate_arn != ""
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = var.site_domain
  default_root_object = "index.html"
  aliases             = local.custom_domain ? concat([var.site_domain], var.extra_aliases) : []
  price_class         = var.price_class

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-${aws_s3_bucket.site.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-${aws_s3_bucket.site.id}"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    dynamic "function_association" {
      for_each = var.viewer_request_function_arn != "" ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = var.viewer_request_function_arn
      }
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = var.error_page_path
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.custom_domain ? null : true
    acm_certificate_arn            = local.custom_domain ? var.acm_certificate_arn : null
    ssl_support_method             = local.custom_domain ? "sni-only" : null
    minimum_protocol_version       = local.custom_domain ? "TLSv1.2_2021" : null
  }
}

# --- Bucket policy: allow only this distribution to read --------------------

data "aws_iam_policy_document" "s3_cloudfront" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.s3_cloudfront.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}
