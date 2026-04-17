terraform {
  required_version = ">= 1.9.0"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = "~> 2.8"
    }
  }
  backend "s3" {
    # Configure via -backend-config at init time
    # bucket = "tf-state-ocp"
    # key    = "infra_project/ocp/terraform.tfstate"
    # region = "us-east-1"
  }
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = false
}
