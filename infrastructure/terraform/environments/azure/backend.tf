terraform {
  cloud {
    organization = "kelbron"

    workspaces {
      name = "k3s-lab-azure"
    }
  }
}
