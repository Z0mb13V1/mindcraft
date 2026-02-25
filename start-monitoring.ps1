# Start monitoring stack (Prometheus, Grafana, node-exporter, cadvisor)
# Auto-provisions Grafana with Prometheus data source and Node Exporter Full dashboard

docker-compose -f docker-compose.monitoring.yml up -d
Write-Host "Monitoring stack started. Access Grafana at http://localhost:3004 (admin/admin). Dashboards and data source are auto-provisioned."