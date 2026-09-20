# Access to graphana

aws ssm start-session \
  --target $(terraform output -raw kdb_instance_id) \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6007"],"localPortNumber":["6007"]}'
