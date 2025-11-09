variable "prefix" {
  description = "Prefix used for naming all Azure resources"
  type        = string
  default     = "sentimentapi"
}

variable "location" {
  description = "Azure region to deploy resources"
  type        = string
  default     = "East US"
}
