variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "k8s-hs"
}

variable "cluster_vip" {
  description = "The vip for the Talos cluster"
  type        = string
  default     = "10.0.0.5"
}

variable "cluster_endpoint" {
  description = "The endpoint for the Talos cluster"
  type        = string
  default     = "https://10.0.0.5:6443"
}

variable "node_data" {
  description = "A map of node data"
  type = object({
    controlplanes = map(object({
      install_disk = string
      interface    = string
      second_disk  = optional(string)
      hostname     = optional(string)
    }))
    workers = map(object({
      install_disk = string
      hostname     = optional(string)
    }))
  })
  default = {
    controlplanes = {
      "10.0.0.11" = {
        install_disk = "/dev/nvme0n1"
        interface    = "eno1"
        second_disk  = "/dev/sda"
      },
      "10.0.0.12" = {
        install_disk = "/dev/nvme0n1"
        interface    = "eno1"
        second_disk  = "/dev/sda"
      },
    }
    workers = {}
  }
}