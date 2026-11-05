# Usado para exibir a URL do SonarQube e o comando SSH para acessar a VM do SonarQube.
output "sonar_url" {
  value = "http://${google_compute_address.sonarqube.address}:9000"
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.sonarqube.name} --zone ${var.zone} --tunnel-through-iap --project ${var.project_id}"
}
