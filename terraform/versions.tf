terraform {
  required_version = ">= 1.7"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.81"
    }
  }

  # No backend block: this config is never applied. A real setup adds an
  # azurerm backend (encrypted, access-restricted storage), see README.md.
}

provider "azurerm" {
  features {}
}
