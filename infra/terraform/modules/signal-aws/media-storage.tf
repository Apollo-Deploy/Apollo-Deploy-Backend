module "media_storage" {
  source = "./modules/media-storage"

  bucket_name_prefix             = var.bucket_name_prefix
  region                         = var.region
  bucket_name_overrides          = var.bucket_name_overrides
  template_media_allowed_origins = var.template_media_allowed_origins
  messaging_kms_key_arn          = module.messaging_encryption.key_arn
  tags                           = var.tags
}
